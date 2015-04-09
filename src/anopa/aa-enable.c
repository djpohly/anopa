/*
 * anopa - Copyright (C) 2015 Olivier Brunel
 *
 * aa-enable.c
 * Copyright (C) 2015 Olivier Brunel <jjk@jjacky.com>
 *
 * This file is part of anopa.
 *
 * anopa is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software
 * Foundation, either version 3 of the License, or (at your option) any later
 * version.
 *
 * anopa is distributed in the hope that it will be useful, but WITHOUT ANY
 * WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
 * FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with
 * anopa. If not, see http://www.gnu.org/licenses/
 */

#define _BSD_SOURCE
#define _GNU_SOURCE

#include "anopa/config.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>
#include <getopt.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <skalibs/bytestr.h>
#include <skalibs/stralloc.h>
#include <skalibs/genalloc.h>
#include <skalibs/direntry.h>
#include <skalibs/strerr2.h>
#include <skalibs/error.h>
#include <skalibs/uint.h>
#include <skalibs/skamisc.h>
#include <anopa/common.h>
#include <anopa/output.h>
#include <anopa/init_repo.h>
#include <anopa/scan_dir.h>
#include <anopa/enable_service.h>
#include <anopa/ga_int_list.h>
#include <anopa/stats.h>
#include <anopa/err.h>
#include "util.h"


#define SVSCANDIR       ".scandir/.s6-svscan"
#define SCANDIR_CRASH   SVSCANDIR "/crash"
#define SCANDIR_FINISH  SVSCANDIR "/finish"

#define SOURCE_ETC      "/etc/anopa/services"
#define SOURCE_USR      "/usr/lib/services"

static aa_enable_flags flags = AA_FLAG_AUTO_ENABLE_NEEDS | AA_FLAG_AUTO_ENABLE_WANTS;
static stralloc sa_pl = STRALLOC_ZERO;
static const char *cur_name = NULL;
static stralloc names = STRALLOC_ZERO;
static int nb_enabled = 0;
static genalloc ga_failed = GENALLOC_ZERO;
static genalloc ga_next = GENALLOC_ZERO;
static const char *skip = NULL;

static void
warn_cb (const char *name, int err)
{
    aa_put_warn (cur_name, name, 0);
    aa_bs_noflush (AA_ERR, ": ");
    aa_bs_noflush (AA_ERR, error_str (err));
    aa_end_warn ();
}

static void
ae_cb (const char *name, aa_enable_flags type)
{
    int i;

    for (i = 0; i < names.len; i += strlen (names.s + i) + 1)
        if (str_equal (name, names.s + i))
            return;

    genalloc_append (int, &ga_next, &names.len);
    stralloc_catb (&names, name, strlen (name) + 1);
}

static int
enable_service (const char *name, int from_next)
{
    int offset;
    int r;
    int i;

    if (*name == '/')
        cur_name = name + byte_rchr (name, strlen (name), '/') + 1;
    else
        cur_name = name;

    if (!from_next)
    {
        /* skip what's already planned to be done next (added via auto-enable) */
        for (i = 0; i < genalloc_len (int, &ga_next); ++i)
            if (str_equal (cur_name, names.s + list_get (&ga_next, i)))
            {
                /* just a name, we can skip it (and process it later). Saves the
                 * memmove needed to remove from ga_next */
                if (cur_name == name)
                    goto done;
                /* there's a config folder, so we need to process it right now
                 * (and remove it from ga_next) */
                offset = list_get (&ga_next, i);
                ga_remove (int, &ga_next, i);
                goto process;
            }

        offset = names.len;
        stralloc_catb (&names, cur_name, strlen (cur_name) + 1);
    }
    else
        offset = from_next - 1;

process:
    if (skip && str_equal (cur_name, skip))
        flags |= AA_FLAG_SKIP_DOWN;
    r = aa_enable_service (name, warn_cb, flags, ae_cb);
    flags &= ~AA_FLAG_SKIP_DOWN;
    if (r < 0)
    {
        int e = errno;

        aa_put_err (cur_name, errmsg[-r], r != -ERR_IO);
        if (r == -ERR_IO)
        {
            aa_bs_noflush (AA_ERR, ": ");
            aa_bs_noflush (AA_ERR, error_str (e));
            aa_end_err ();
        }

        genalloc_append (int, &ga_failed, &offset);
        cur_name = NULL;
        return -1;
    }

    ++nb_enabled;
done:
    cur_name = NULL;
    return 0;
}

static int
it_list (direntry *d, void *data)
{
    if (*d->d_name == '.')
        return 0;
    else if (d->d_type != DT_DIR)
        enable_service (d->d_name, 0);
    else
    {
        int l;

        l = sa_pl.len;
        sa_pl.s[l - 1] = '/';
        stralloc_catb (&sa_pl, d->d_name, str_len (d->d_name) + 1);
        enable_service (sa_pl.s, 0);
        sa_pl.len = l;
        sa_pl.s[l - 1] = '\0';
    }
    return 0;
}

static void
dieusage (int rc)
{
    aa_die_usage (rc, "[OPTION...] [service...]",
            " -D, --double-output           Enable double-output mode\n"
            " -r, --repodir DIR             Use DIR as repository directory\n"
            " -S, --reset-source DIR        Reset list of source directories to DIR\n"
            " -s, --source DIR              Add DIR as source directories\n"
            " -k, --skip-down SERVICE       Don't create file 'down' for SERVICE\n"
            " -l, --listdir DIR             Use DIR to list services to enable\n"
            " -f, --set-finish TARGET       Create s6-svscan symlink finish to TARGET\n"
            " -c, --set-crash TARGET        Create s6-svscan symlink crash to TARGET\n"
            " -n, --no-needs                Don't auto-enable services from 'needs'\n"
            " -w, --no-wants                Don't auto-enable services from 'wants'\n"
            " -h, --help                    Show this help screen and exit\n"
            " -V, --version                 Show version information and exit\n"
            );
}

int
main (int argc, char * const argv[])
{
    PROG = "aa-enable";
    const char *path_repo = "/run/services";
    const char *path_list = NULL;
    const char *set_crash = NULL;
    const char *set_finish = NULL;
    int mode_both = 0;
    int i;
    int r;

    if (!stralloc_catb (&aa_sa_sources, SOURCE_ETC, sizeof (SOURCE_ETC)))
        strerr_diefu1sys (1, "stralloc_catb");
    if (!stralloc_catb (&aa_sa_sources, SOURCE_USR, sizeof (SOURCE_USR)))
        strerr_diefu1sys (1, "stralloc_catb");

    for (;;)
    {
        struct option longopts[] = {
            { "set-crash",          required_argument,  NULL,   'c' },
            { "double-output",      no_argument,        NULL,   'D' },
            { "set-finish",         required_argument,  NULL,   'f' },
            { "help",               no_argument,        NULL,   'h' },
            { "skip-down",          required_argument,  NULL,   'k' },
            { "listdir",            required_argument,  NULL,   'l' },
            { "no-needs",           no_argument,        NULL,   'n' },
            { "repodir",            required_argument,  NULL,   'r' },
            { "reset-source",       required_argument,  NULL,   'S' },
            { "source",             required_argument,  NULL,   's' },
            { "version",            no_argument,        NULL,   'V' },
            { "no-wants",           no_argument,        NULL,   'w' },
            { NULL, 0, 0, 0 }
        };
        int c;

        c = getopt_long (argc, argv, "c:Df:hk:l:nr:S:s:Vw", longopts, NULL);
        if (c == -1)
            break;
        switch (c)
        {
            case 'c':
                set_crash = optarg;
                break;

            case 'D':
                mode_both = 1;
                break;

            case 'f':
                set_finish = optarg;
                break;

            case 'h':
                dieusage (0);

            case 'k':
                skip = optarg;
                break;

            case 'l':
                unslash (optarg);
                path_list = optarg;
                break;

            case 'n':
                flags &= ~AA_FLAG_AUTO_ENABLE_NEEDS;
                break;

            case 'r':
                unslash (optarg);
                path_repo = optarg;
                break;

            case 'S':
                aa_sa_sources.len = 0;
                /* fall through */

            case 's':
                unslash (optarg);
                if (!stralloc_catb (&aa_sa_sources, optarg, strlen (optarg) + 1))
                    strerr_diefu1sys (1, "stralloc_catb");
                break;

            case 'V':
                aa_die_version ();

            case 'w':
                flags &= ~AA_FLAG_AUTO_ENABLE_WANTS;
                break;

            default:
                dieusage (1);
        }
    }
    argc -= optind;
    argv += optind;

    aa_init_output (mode_both);

    if (!path_list && argc < 1)
        dieusage (1);

    r = aa_init_repo (path_repo, AA_REPO_CREATE);
    if (r < 0)
    {
        if (r == -ERR_IO_REPODIR)
            strerr_diefu2sys (1, "create repository ", path_repo);
        else if (r == -ERR_IO_SCANDIR)
            strerr_diefu3sys (1, "create scandir ", path_repo, "/" AA_SCANDIR_DIRNAME);
        else
            strerr_diefu2sys (1, "init repository ", path_repo);
    }

    /* process listdir (path_list) first, to ensure if the service was also
     * specified on cmdline (and will fail: already exists) the one processed is
     * the one with (potentially) a config dir */
    if (path_list)
    {
        stralloc_catb (&sa_pl, path_list, strlen (path_list) + 1);
        r = aa_scan_dir (&sa_pl, 0, it_list, NULL);
        if (r < 0)
            strerr_diefu2sys (-r, "read list directory ", path_list);
    }

    for (i = 0; i < argc; ++i)
        enable_service (argv[i], 0);

    while (genalloc_len (int, &ga_next) > 0)
    {
        int offset;

        i = genalloc_len (int, &ga_next) - 1;
        offset = list_get (&ga_next, i);
        genalloc_setlen (int, &ga_next, i);
        enable_service (names.s + offset, 1 + offset);
    }

    aa_bs_noflush (AA_OUT, "\n");
    aa_put_title (1, PROG, "Completed", 1);
    aa_show_stat_nb (nb_enabled, "Enabled", ANSI_HIGHLIGHT_GREEN_ON);
    aa_show_stat_names (names.s, &ga_failed, "Failed", ANSI_HIGHLIGHT_RED_ON);

    if ((set_crash || set_finish) && mkdir (SVSCANDIR, S_IRWXU) < 0)
        aa_put_err ("Failed to create " SVSCANDIR, error_str (errno), 1);
    if (set_crash && symlink (set_crash, SCANDIR_CRASH) < 0)
        aa_put_err ("Failed to create symlink " SCANDIR_CRASH, error_str (errno), 1);
    if (set_finish && symlink (set_finish, SCANDIR_FINISH) < 0)
        aa_put_err ("Failed to create symlink " SCANDIR_FINISH, error_str (errno), 1);

    genalloc_free (int, &ga_failed);
    genalloc_free (int, &ga_next);
    stralloc_free (&sa_pl);
    stralloc_free (&names);
    return 0;
}
