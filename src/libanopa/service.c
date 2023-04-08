/*
 * anopa - Copyright (C) 2015-2017 Olivier Brunel
 *
 * service.c
 * Copyright (C) 2015-2017 Olivier Brunel <jjk@jjacky.com>
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

#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <skalibs/djbunix.h> /* fd_close() */
#include <skalibs/stralloc.h>
#include <skalibs/genalloc.h>
#include <skalibs/bytestr.h>
#include <skalibs/direntry.h>
#include <skalibs/types.h>
#include <skalibs/tai.h>
#include <s6/supervise.h>
#include <s6/ftrigr.h>
#include <anopa/service.h>
#include <anopa/ga_int_list.h>
#include <anopa/scan_dir.h>
#include <anopa/err.h>
#include <anopa/output.h>
#include "service_internal.h"

#define NOTIFICATION_FILENAME       "notification-fd"

static aa_close_fd_fn close_fd;

static void
free_service (aa_service *s)
{
    genalloc_free (int, &s->needs);
    genalloc_free (int, &s->wants);
    genalloc_free (int, &s->after);
    aa_service_status_free (&s->st);
    if (s->fd_out > 0)
        close_fd (s->fd_out);
    if (s->fd_progress > 0)
        close_fd (s->fd_progress);
    stralloc_free (&s->sa_out);
}

void
aa_free_services (aa_close_fd_fn _close_fd)
{
    if (_close_fd)
        close_fd = _close_fd;
    else
        close_fd = (aa_close_fd_fn) fd_close;
    genalloc_deepfree (aa_service, &aa_services, free_service);
}

size_t
aa_add_name (const char *name)
{
    size_t offset = aa_names.len;
    if (!stralloc_catb (&aa_names, name, strlen (name) + 1))
        return (size_t) -1;
    return offset;
}

static int
get_new_service (const char *name)
{
    aa_service s = {
        .nb_mark = 0,
        .needs = GENALLOC_ZERO,
        .wants = GENALLOC_ZERO,
        .after = GENALLOC_ZERO,
        .ls = AA_LOAD_NOT,
        .st.event = AA_EVT_NONE,
        .st.sa = STRALLOC_ZERO,
        .st.type = AA_TYPE_UNKNOWN,
        .ft_id = 0,
        .sa_out = STRALLOC_ZERO,
        .pi = -1
    };
    struct stat st;

    if (!_is_valid_service_name (name, strlen (name)))
        return -ERR_INVALID_NAME;

    if (stat (name, &st) < 0)
    {
        if (errno == ENOENT)
            return -ERR_UNKNOWN;
        else
            return -ERR_IO;
    }
    else if (!S_ISDIR (st.st_mode))
        return (errno = ENOTDIR, -ERR_IO);

    s.offset_name = aa_add_name (name);
    if (s.offset_name == (size_t) -1)
        return (errno = ENOMEM, -ERR_UNKNOWN);
    genalloc_append (aa_service, &aa_services, &s);
    return genalloc_len (aa_service, &aa_services) - 1;
}

static int
get_from_list (genalloc *list, const char *name)
{
    size_t l = genalloc_len (int, list);
    size_t i;

    for (i = 0; i < l; ++i)
        if (!str_diff (name, aa_service_name (aa_service (list_get (list, i)))))
            return list_get (list, i);

    return -1;
}

int
aa_get_service (const char *name, int *si, int new_in_main)
{
    *si = get_from_list (&aa_main_list, name);
    if (*si >= 0)
        return AA_SERVICE_FROM_MAIN;

    *si = get_from_list (&aa_tmp_list, name);
    if (*si >= 0)
        return AA_SERVICE_FROM_TMP;

    *si = get_new_service (name);
    if (*si < 0)
        return *si;

    if (new_in_main)
    {
        add_to_list (&aa_main_list, *si, 0);
        return AA_SERVICE_FROM_MAIN;
    }
    else
    {
        add_to_list (&aa_tmp_list, *si, 0);
        return AA_SERVICE_FROM_TMP;
    }
}

static int
contains_fd (const char *filename)
{
    char buf[UINT_FMT + 1];
    ssize_t r;

    r = openreadnclose_nb (filename, buf, UINT_FMT);
    if (r < 0)
    {
        if (errno != ENOENT)
            aa_strerr_warnu2sys ("open ", filename);
        return 0;
    }

    {
        unsigned int i = r;

        buf[byte_chr (buf, i, '\n')] = '\0';
        if (!uint0_scan (buf, &i))
        {
            aa_strerr_warn2x ("invalid ", filename);
            return 0;
        }
    }

    return 1;
}

int
aa_preload_service (int si)
{
    aa_service_status *svst = &aa_service (si)->st;
    size_t l_sn = strlen (aa_service_name (aa_service (si)));
    char buf[l_sn + 1 + sizeof (NOTIFICATION_FILENAME)];

    byte_copy (buf, l_sn, aa_service_name (aa_service (si)));
    byte_copy (buf + l_sn, 5, "/run");

    if (access (buf, F_OK) < 0)
    {
        if (errno != ENOENT)
            return -ERR_IO;
        else
            svst->type = AA_TYPE_ONESHOT;
    }
    else
    {
        svst->type = AA_TYPE_LONGRUN;
        aa_service (si)->gets_ready = 0;

        byte_copy (buf + l_sn, 1 + sizeof (AA_GETS_READY_FILENAME), "/" AA_GETS_READY_FILENAME);
        if (access (buf, F_OK) == 0)
            aa_service (si)->gets_ready = 1;
        else
        {
            byte_copy (buf + l_sn, 1 + sizeof (NOTIFICATION_FILENAME), "/" NOTIFICATION_FILENAME);
            if (access (buf, F_OK) == 0 && contains_fd (buf))
                aa_service (si)->gets_ready = 1;
        }
    }

    return 0;
}

int
aa_ensure_service_loaded (int si, aa_mode mode, int no_wants, aa_autoload_cb al_cb)
{
    stralloc sa = STRALLOC_ZERO;
    struct it_data it_data = {
        .mode = mode,
        .si = si,
        .no_wants = no_wants,
        .al_cb = al_cb
    };
    int r;

    if (aa_service (si)->ls == AA_LOAD_DONE || aa_service (si)->ls == AA_LOAD_ING)
        return 0;
    else if (aa_service (si)->ls == AA_LOAD_FAIL)
        return -aa_service (si)->st.code;

    r = aa_preload_service (si);
    if (r < 0)
        return r;

    {
        aa_service_status *svst = &aa_service (si)->st;
        int chk_st;
        int is_up;

        chk_st = aa_service_status_read (svst, aa_service_name (aa_service (si))) == 0;
        is_up = 0;

        if (svst->type == AA_TYPE_LONGRUN)
        {
            s6_svstatus_t st6 = S6_SVSTATUS_ZERO;

            if (s6_svstatus_read (aa_service_name (aa_service (si)), &st6))
            {
                chk_st = 0;
                is_up = st6.pid && !st6.flagfinishing;
                if (is_up && aa_service (si)->gets_ready && st6.flagready)
                    is_up = 2;
                else if ((mode & (AA_MODE_STOP | AA_MODE_STOP_ALL))
                            && !is_up && st6.flagwantup)
                    /* it is down, but to be restarted soon by s6-supervise; so
                     * for our intent & purposes, it shall be considered up, so
                     * that we stop the restart and place the down file.
                     * (When starting, it's ok to send the up command, so we
                     * should still consider it down then.) */
                    is_up = 1;
            }
            else if (errno != ENOENT)
            {
                /* most likely a permission error on supervise folder */
                r = -ERR_IO;
                goto err;
            }
            tain_now_g ();
        }

        if (chk_st)
            is_up = (svst->event == AA_EVT_STARTED || svst->event == AA_EVT_STARTING
                    || svst->event == AA_EVT_STOPPING_FAILED
                    || svst->event == AA_EVT_STOP_FAILED);

        /* DRY_FULL means process (i.e. list) even services that are already in
         * the right state, so skip that bit then */
        if (!(mode & AA_MODE_IS_DRY_FULL))
        {
            if (mode & AA_MODE_START)
            {
                /* if it is a longrun w/ readiness support that isn't yet ready,
                 * we load the service to add it to the "transaction" since
                 * we'll need to wait for its readyness.
                 * We set the code to 0 or ERR_ALREADY_UP to indicate whether it
                 * was alreayd up or not, so when starting it (in exec_cb) it
                 * can actually be said "Starting" or "Getting ready" as needed.
                 */
                if (svst->type == AA_TYPE_LONGRUN && aa_service (si)->gets_ready && is_up < 2)
                    svst->code = (is_up == 1) ? ERR_ALREADY_UP : 0;
                else if (is_up)
                {
                    /* if already good, we "fail" because there's no need to
                     * load the service, it's already good. This error will be
                     * silently ignored */
                    aa_service (si)->ls = AA_LOAD_FAIL;
                    /* this isn't actually true, but we won't save it to file */
                    svst->code = ERR_ALREADY_UP;
                    return -ERR_ALREADY_UP;
                }
            }
            else if ((mode & (AA_MODE_STOP | AA_MODE_STOP_ALL)) && !is_up)
            {
                /* if not up, we "fail" because we can't stop it */
                aa_service (si)->ls = AA_LOAD_FAIL;
                /* this isn't actually true, but we won't save it to file */
                svst->code = ERR_NOT_UP;
                return -ERR_NOT_UP;
            }
        }
    }

    aa_service (si)->ls = AA_LOAD_ING;

    stralloc_cats (&sa, aa_service_name (aa_service (si)));

    /* special case: for a longrun that's not a logger, we check if it has one,
     * and if so auto-add needs & after on said logger */
    if (aa_service (si)->st.type == AA_TYPE_LONGRUN
            /* because sa.s is the service name, and the only slashes allowed
             * are for loggers, i.e. xxxx/log */
            && (sa.len < 5 || sa.s[sa.len - 4] != '/'))
    {
        stralloc_catb (&sa, "/log/run", strlen ("/log/run") + 1);
        r = access (sa.s, F_OK);
        if (r < 0 && (errno != ENOTDIR && errno != ENOENT))
            goto err;

        if (r == 0)
        {
            sa.s[sa.len - 5] = '\0';
            if (mode & AA_MODE_START)
                r = _name_start_needs (sa.s, &it_data);
            else
                r = _name_stop_needs (sa.s, &it_data);
            if (r < 0)
                goto err;
        }

        sa.len -= strlen ("/log/run") + 1;
    }

    stralloc_catb (&sa, "/needs", strlen ("/needs") + 1);
    r = aa_scan_dir (&sa, 1,
            (mode & AA_MODE_START) ? _it_start_needs : _it_stop_needs,
            &it_data);
    /* we can get ERR_IO either from aa_scan_dir() itself, or from the iterator
     * function. But since we haven't checked that the directory (needs) does
     * exist, ERR_IO w/ ENOENT simply means it doesn't, and isn't an error.
     * This works because there's no ENOENT from aa_get_service(), since that
     * won't be an ERR_IO but an ERR_UNKNOWN */
    if (r < 0 && (r != -ERR_IO || errno != ENOENT))
        goto err;

    sa.len -= strlen ("needs") + 1;
    if ((mode & AA_MODE_START) && !no_wants)
    {
        stralloc_catb (&sa, "wants", strlen ("wants") + 1);
        r = aa_scan_dir (&sa, 1, _it_start_wants, &it_data);
        if (r < 0 && (r != -ERR_IO || errno != ENOENT))
            goto err;

        sa.len -= strlen ("wants") + 1;
    }
    stralloc_catb (&sa, "after", strlen ("after") + 1);
    r = aa_scan_dir (&sa, 1,
            (mode & AA_MODE_START) ? _it_start_after : _it_stop_after,
            &it_data);
    if (r < 0 && (r != -ERR_IO || errno != ENOENT))
        goto err;

    sa.len -= strlen ("after") + 1;
    stralloc_catb (&sa, "before", strlen ("before") + 1);
    r = aa_scan_dir (&sa, 1,
            (mode & AA_MODE_START) ? _it_start_before : _it_stop_before,
            &it_data);
    if (r < 0 && (r != -ERR_IO || errno != ENOENT))
        goto err;

    {
        char buf[UINT_FMT + 1];
        ssize_t rr;

        sa.len -= strlen ("before") + 1;
        stralloc_catb (&sa, "timeout", strlen ("timeout") + 1);

        rr = openreadnclose_nb (sa.s, buf, UINT_FMT);
        if (rr < 0 && errno != ENOENT)
            aa_strerr_warnu3x ("read timeout for ", aa_service_name (aa_service (si)), "; using default");

        if (rr >= 0)
        {
            unsigned int i = rr;

            buf[byte_chr (buf, i, '\n')] = '\0';
            if (!uint0_scan (buf, &i))
            {
                aa_strerr_warn3x ("invalid timeout for ", aa_service_name (aa_service (si)), "; using default");
                aa_service (si)->secs_timeout = aa_secs_timeout;
            }
            /* in STOP_ALL the default is also a maximum */
            else if ((mode & AA_MODE_STOP_ALL)
                    && (aa_service (si)->secs_timeout > aa_secs_timeout
                        || aa_service (si)->secs_timeout == 0))
                aa_service (si)->secs_timeout = aa_secs_timeout;
        }
        else
            aa_service (si)->secs_timeout = aa_secs_timeout;
    }

    stralloc_free (&sa);
    aa_service (si)->ls = AA_LOAD_DONE;
    tain_now_g ();
    return 0;

err:
    aa_service (si)->ls = AA_LOAD_FAIL;
    stralloc_free (&sa);
    tain_now_g ();
    return r;
}

static int
check_afters (int si, int *sli, int *has_longrun)
{
    aa_service *s = aa_service (si);
    size_t org = genalloc_len (int, &aa_tmp_list);
    size_t i;

    if (s->ls == AA_LOAD_DONE_CHECKED)
        return 0;

    if (!add_to_list (&aa_tmp_list, si, 1))
    {
        *sli = si;
        return -1;
    }

    for (i = 0; i < genalloc_len (int, &s->after); )
    {
        int sai;

        sai = list_get (&s->after, i);
        if ((aa_service (sai)->ls != AA_LOAD_DONE
                    && aa_service (sai)->ls != AA_LOAD_DONE_CHECKED)
                || !is_in_list (&aa_main_list, sai))
        {
            remove_from_list (&s->after, sai);
            continue;
        }

        if (check_afters (sai, sli, has_longrun) < 0)
            return -1;
        ++i;
    }

    if (s->st.type == AA_TYPE_LONGRUN && !*has_longrun)
        *has_longrun = 1;

    genalloc_setlen (int, &aa_tmp_list, org);
    s->ls = AA_LOAD_DONE_CHECKED;

    return 0;
}

int
aa_prepare_mainlist (aa_prepare_cb prepare_cb, aa_exec_cb exec_cb)
{
    int has_longrun = 0;
    size_t i;

    _exec_cb = exec_cb;
    aa_tmp_list.len = 0;

    /* scan main_list to remove unneeded afters and check for loops */
    for (i = 0; i < genalloc_len (int, &aa_main_list); )
    {
        int si;
        int sli;

        si = list_get (&aa_main_list, i);

        /* check the after-s of the service, recursively. It will remove any
         * after that's not loaded or in the main list, i.e. that won't be
         * started.
         * It also constructs a list going down, to find any loop (e.g. a after
         * b after a), placing it in aa_tmp_list. Should be noted that the list
         * might be "a,b,c,d" with sli set to c if the loop is actually c->d->c
         * but was found from b which was itself after a; hence we need to find
         * the "real" start of the loop.
         */
        if (check_afters (si, &sli, &has_longrun) < 0)
        {
            size_t l;
            size_t j;
            size_t found = 0;

            add_to_list (&aa_tmp_list, sli, 0);
            l = genalloc_len (int, &aa_tmp_list);
            for (j = 0; j < l - 1; ++j)
            {
                int cur;
                int next;

                cur = list_get (&aa_tmp_list, j);
                if (!found && cur == sli)
                    found = j + 1;
                if (!found)
                    continue;

                next = list_get (&aa_tmp_list, j + 1);
                /* remove the first after link that's not a need as well */
                if (!is_in_list (&aa_service (cur)->needs, next))
                {
                    remove_from_list (&aa_service (cur)->after, next);
                    if (prepare_cb)
                        prepare_cb (cur, next, 0, found - 1);
                    break;
                }
            }

            /* this is actually a loop of needs */
            if (j >= l - 1)
            {
                int cur;
                int next;

                /* we'll remove the last one (both needs & after) on the loop,
                 * so the further one away from the explicitly asked to start
                 * service, so it might break it less... though that really
                 * doesn't mean much, plus it might also have been explicitly
                 * asked as well. Either way, major config error, fix it user! */
                cur = list_get (&aa_tmp_list, l - 2);
                next = list_get (&aa_tmp_list, l - 1);

                remove_from_list (&aa_service (cur)->needs, next);
                remove_from_list (&aa_service (cur)->after, next);
                if (prepare_cb)
                    prepare_cb (cur, next, 1, found - 1);
            }
        }
        else
            ++i;

       aa_tmp_list.len = 0;
    }

    if (has_longrun)
    {
        tain deadline;

        tain_addsec_g (&deadline, 1);
        if (!ftrigr_startf_g (&_aa_ft, &deadline))
            return -1;
        else
            return ftrigr_fd (&_aa_ft);
    }

    return 0;
}

static int
service_is_ok (aa_mode mode, aa_service *s)
{
    aa_service_status *svst = &s->st;
    s6_svstatus_t st6 = S6_SVSTATUS_ZERO;
    aa_evt event;
    int r;

    /* if DRY we assume it's ok, since it wasn't really started/stopped.
     * if STOP_ALL we pretend it's ok since we're trying to stop everything. */
    if (mode & (AA_MODE_IS_DRY | AA_MODE_STOP_ALL))
        return 1;

    if (svst->type == AA_TYPE_ONESHOT)
    {
        event = (mode & AA_MODE_START) ? AA_EVT_STARTED : AA_EVT_STOPPED;
        return (svst->event == event) ? 1 : 0;
    }

    /* TYPE_LONGRUN -- we make assumptions here:
     * - we have a local status, since we started the service
     * - if it's flagged timedout, that's a fail (flag is used to avoid possible
     *   race condition: it was processed as timedout (might be for readiness)
     *   and by the time we're checking here, s6 state has changed (e.g. it now
     *   is ready, or down...) This should obviously remain a fail, not assume
     *   it was good (e.g. ready) & process it as success.)
     * - if there's no s6 status, that's a fail (probably fail to even exec run)
     * - we compare stamp, if s6 is more recent, it's good (since we got the
     *   event we were waiting for); else it's a fail (must be our
     *   EVT_STARTING_FAILED, might be an ERR_TIMEDOUT if we're still waiting
     *   for the 'U' event (ready)). Actually we'll allow for our event to be
     *   EVT_STARTING because there's a possible race condition there.
     */
    event = (mode & AA_MODE_START) ? AA_EVT_STARTING : AA_EVT_STOPPING;
    if (!s->timedout && s6_svstatus_read (aa_service_name (s), &st6)
            && (tain_less (&svst->stamp, &st6.stamp) || svst->event == event))
        r = 1;
    else
        r = 0;

    tain_now_g ();
    return r;
}

void
aa_scan_mainlist (aa_scan_cb scan_cb, aa_mode mode)
{
    size_t i;

    for (i = 0; i < genalloc_len (int, &aa_main_list); )
    {
        aa_service *s;
        int si;
        size_t j;

        si = list_get (&aa_main_list, i);
        s = aa_service (si);

        for (j = 0; j < genalloc_len (int, &s->needs); )
        {
            int sni;
            aa_service_status *svst;

            sni = list_get (&s->needs, j);
            if (is_in_list (&aa_main_list, sni))
            {
                ++j;
                continue;
            }

            if (service_is_ok (mode, aa_service (sni)))
            {
                remove_from_list (&s->needs, sni);
                remove_from_list (&s->after, sni);
                continue;
            }

            svst = &s->st;
            svst->event = (mode & AA_MODE_START) ? AA_EVT_STARTING_FAILED: AA_EVT_STOPPING_FAILED;
            svst->code = ERR_DEPEND;
            tain_copynow (&svst->stamp);
            aa_service_status_set_msg (svst, aa_service_name (aa_service (sni)));
            if (aa_service_status_write (svst, aa_service_name (s)) < 0)
                aa_strerr_warnu2sys ("write service status file for ", aa_service_name (s));

            remove_from_list (&aa_main_list, si);

            if (scan_cb)
                scan_cb (si, sni);

            si = -1;
            break;
        }
        if (si < 0)
        {
            i = 0;
            continue;
        }

        for (j = 0; j < genalloc_len (int, &s->after); )
        {
            int sai;

            sai = list_get (&s->after, j);
            if (is_in_list (&aa_main_list, sai))
                ++j;
            else
                remove_from_list (&s->after, sai);
        }

        if (genalloc_len (int, &s->after) == 0
                && (
                    /* either we're in DRY mode (i.e. we should start it) */
                    (mode & AA_MODE_IS_DRY)
                    ||
                    /* or make sure it's in the right state */
                    (((mode & AA_MODE_START) && s->st.event != AA_EVT_STARTING)
                     || ((mode & (AA_MODE_STOP | AA_MODE_STOP_ALL))
                         && s->st.event != AA_EVT_STOPPING))
                    )
                && aa_exec_service (si, mode) < 0)
            /* failed to exec service, was removed from main_list, so we need to
             * rescan from top */
            i = -1;

        ++i;
    }
}

int
aa_exec_service (int si, aa_mode mode)
{
    int r = 0;

    if (_exec_cb)
        /* ugly hack to announce "Starting/Stopping foobar..."; needed because
         * we use common code for aa-start & aa-stop, so... yeah */
        _exec_cb (si, 0, (pid_t) mode);

    tain_now_g ();
    tain_copynow (&aa_service (si)->ts_exec);
    if (!(mode & AA_MODE_IS_DRY))
    {
        if (aa_service (si)->st.type == AA_TYPE_ONESHOT)
            r = _exec_oneshot (si, mode);
        else
            r = _exec_longrun (si, mode);

        if (r < 0)
            remove_from_list (&aa_main_list, si);
    }

    return r;
}
