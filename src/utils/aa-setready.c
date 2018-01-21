/*
 * anopa - Copyright (C) 2015-2017 Olivier Brunel
 *
 * aa-setready.c
 * Copyright (C) 2015-2018 Olivier Brunel <jjk@jjacky.com>
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

#include <getopt.h>
#include <errno.h>
#include <unistd.h>
#include <skalibs/djbunix.h>
#include <skalibs/bytestr.h>
#include <s6/ftrigw.h>
#include <s6/s6-supervise.h>
#include <anopa/common.h>
#include <anopa/output.h>

enum
{
    RC_ST_READ      = 1 << 1,
    RC_ST_NOT_UP    = 2 << 1,
    RC_ST_CLOCK     = 3 << 1,
    RC_ST_WRITE     = 4 << 1,
    RC_ST_EVENT     = 5 << 1
};

static void
dieusage (int rc)
{
    aa_die_usage (rc, "[OPTION] SERVICEDIR",
            " -D, --double-output           Enable double-output mode\n"
            " -O, --log-file FILE|FD        Write log to FILE|FD\n"
            " -U, --ready                   Mark service ready; This is the default.\n"
            " -N, --unready                 Mark service not ready\n"
            "\n"
            " -h, --help                    Show this help screen and exit\n"
            " -V, --version                 Show version information and exit\n"
            );
}

int
main (int argc, char * const argv[])
{
    PROG = "aa-setready";
    int ready = 1;

    for (;;)
    {
        struct option longopts[] = {
            { "double-output",      no_argument,        NULL,   'D' },
            { "help",               no_argument,        NULL,   'h' },
            { "unready",            no_argument,        NULL,   'N' },
            { "log-file",           required_argument,  NULL,   'O' },
            { "ready",              no_argument,        NULL,   'U' },
            { "version",            no_argument,        NULL,   'V' },
            { NULL, 0, 0, 0 }
        };
        int c;

        c = getopt_long (argc, argv, "DhNO:UV", longopts, NULL);
        if (c == -1)
            break;
        switch (c)
        {
            case 'D':
                aa_set_double_output (1);
                break;

            case 'h':
                dieusage (RC_OK);

            case 'N':
                ready = 0;
                break;

            case 'O':
                aa_set_log_file_or_die (optarg);
                break;

            case 'U':
                ready = 1;
                break;

            case 'V':
                aa_die_version ();

            default:
                dieusage (RC_FATAL_USAGE);
        }
    }
    argc -= optind;
    argv += optind;

    if (argc != 1)
        dieusage (RC_FATAL_USAGE);

    {
        size_t l = strlen (argv[0]);
        char fifodir[l + 1 + sizeof (S6_SUPERVISE_EVENTDIR)];
        s6_svstatus_t st6 = S6_SVSTATUS_ZERO;

        byte_copy (fifodir, l, argv[0]);
        fifodir[l] = '/';
        byte_copy (fifodir + l + 1, sizeof (S6_SUPERVISE_EVENTDIR), S6_SUPERVISE_EVENTDIR);

        if (!s6_svstatus_read (argv[0], &st6))
            aa_strerr_diefu1sys (RC_ST_READ, "read s6 status");
        if (!(st6.pid && !st6.flagfinishing))
            aa_strerr_dief1x (RC_ST_NOT_UP, "service is not up");

        if (ready)
        {
            st6.flagready = 1;
            if (!tain_now (&st6.readystamp))
                aa_strerr_diefu1sys (RC_ST_CLOCK, "init timestamp");
        }
        else
            st6.flagready = 0;

        if (!s6_svstatus_write (argv[0], &st6))
            aa_strerr_diefu1sys (RC_ST_WRITE, "write s6 status");

        if (ftrigw_notify (fifodir, (ready) ? 'U' : 'N') < 0)
            aa_strerr_diefu4sys (RC_ST_EVENT, "send event ", (ready) ? "U": "N" , " via ", fifodir);
    }

    return RC_OK;
}
