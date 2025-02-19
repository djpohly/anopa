/*
 * anopa - Copyright (C) 2015-2017 Olivier Brunel
 *
 * start-stop.h
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

#ifndef AA_START_STOP_H
#define AA_START_STOP_H

#include <signal.h>
#include <sys/types.h>
#include <skalibs/genalloc.h>
#include <skalibs/tai.h>
#include <anopa/service.h>
#include <anopa/progress.h>
#include <anopa/output.h>

#define SECS_BEFORE_WAITING         7
#define DEFAULT_TIMEOUT_SECS        300

#define ANSI_PREV_LINE              "\x1B[F"
#define ANSI_CLEAR_AFTER            "\x1B[K"
#define ANSI_CLEAR_BEFORE           "\x1B[1K"
#define ANSI_START_LINE             "\x1B[1G"

extern genalloc ga_iop;
extern genalloc ga_progress;
extern genalloc ga_pid;
extern tain iol_deadline;
extern unsigned int draw;
extern int nb_already;
extern int nb_done;
extern int nb_wait_longrun;
extern genalloc ga_failed;
extern genalloc ga_timedout;
extern int cols;
extern int is_utf8;
extern int ioloop;
extern int si_password;
extern int si_active;

enum
{
    DRAW_CUR_WAITING    = (1 << 0),
    DRAW_CUR_PROGRESS   = (1 << 1),
    DRAW_CUR_PASSWORD   = (1 << 2),
    DRAW_HAS_CUR        = (1 << 3) - 1,

    DRAW_NEED_WAITING   = (1 << 3),
    DRAW_NEED_PROGRESS  = (1 << 4),
    DRAW_NEED_PASSWORD  = (1 << 5),
    DRAW_HAS_NEED       = (1 << 6) - DRAW_HAS_CUR - 1
};

enum
{
    DRAWN_NOT = 0,
    DRAWN = 1,

    DRAWN_PASSWORD_WAITMSG = -1,
    DRAWN_PASSWORD_READY = -2,
    DRAWN_PASSWORD_WRITING = -3
};

struct progress
{
    aa_progress aa_pg;
    int si;
    int is_drawn;
    int secs_timeout;
};

void free_progress (struct progress *pg);
int refresh_draw ();
void draw_waiting (int already_drawn);
void draw_progress_for (int si);
void clear_draw ();
void add_name_to_ga (const char *name, genalloc *ga);
void iol_deadline_addsec (int n);
void remove_fd_from_iop (int fd);
void close_fd_for (int fd, int si);
int handle_fd_out (int si);
int handle_fd_progress (int si);
int handle_fd_in (void);
int handle_fd (int fd);
int handle_longrun (aa_mode mode, uint16 id, char event);
int is_locale_utf8 (void);
int get_cols (int fd);
int handle_signals (aa_mode mode);
void prepare_cb (int cur, int next, int is_needs, size_t first);
void exec_cb (int si, aa_evt evt, pid_t pid);
void mainloop (aa_mode mode, aa_scan_cb scan_cb);
void show_stat_service_names (genalloc *ga, const char *title, const char *ansi_color);

#define end_err()                       aa_end_err ()
#define put_err(name,msg,end)           do { \
    clear_draw (); \
    aa_put_err (name, msg, end); \
} while (0)
#define add_err(s)                      aa_bs_noflush (AA_ERR, s)
#define put_err_service(name,err,end)   put_err (name, errmsg[err], end)
#define end_warn()                      aa_end_warn ()
#define put_warn(name,msg,end)          do { \
    clear_draw (); \
    aa_put_warn (name, msg, end); \
} while (0)
#define add_warn(s)                     aa_bs_noflush (AA_ERR, s)
#define end_title()                     aa_end_title ()
#define put_title(main,name,title,end)  do { \
    clear_draw (); \
    aa_put_title (main, name, title, end); \
} while (0)
#define add_title(s)                    aa_bs_noflush (AA_OUT, s)

#endif /* AA_START_STOP_H */
