(* Test driver for the golden-file regression suites.

   Usage:
     run_case --exe PROG [--deadline SECONDS] [--setenv VAR=VALUE]... -- ARGS...

   It runs [PROG ARGS...] in its own process group under a wall-clock deadline,
   capturing stdout and stderr separately, and writes one deterministic report
   to its own stdout:

     <normalised stdout>
     --- stderr ---
     <normalised stderr>
     rc=<n>            (or rc=signal(SIGKILL), or rc=timeout)

   run_case itself always exits 0, so a case whose expected exit code is
   non-zero is still a plain [diff] rule; [with-accepted-exit-codes] needs
   dune 2.2 and this project is at (lang dune 2.0).  The deadline is here for
   the same reason: [timeout(1)] is coreutils and absent from stock macOS, so
   it cannot be spelled in a dune rule. *)

let usage () =
  prerr_endline
    "usage: run_case --exe PROG [--deadline SECONDS] [--setenv VAR=VALUE]... \
     -- ARGS...";
  exit 2

(** {2 Normalisation} *)

(* Canonical renaming by first appearance: distinct occurrences stay distinct
   and shared ones stay shared, but the process-level counter is gone.  A
   single table per run, shared by both streams, so an id that appears on
   stdout and on stderr gets one name. *)
let canonicalise re fmt s =
  let seen = Hashtbl.create 16 in
  Str.global_substitute re
    (fun _ ->
       let k = Str.matched_string s in
       match Hashtbl.find_opt seen k with
       | Some v -> v
       | None ->
         let v = Printf.sprintf fmt (Hashtbl.length seen + 1) in
         Hashtbl.add seen k v;
         v)
    s

let re_unknown = Str.regexp "\\?__[0-9]+"
let re_var = Str.regexp "v_[0-9]+/[0-9]+"
let re_time = Str.regexp "time:[0-9]+\\.[0-9]+s"
let re_options = Str.regexp "message=\"options: [^\"]*\""

(* An [UNKNOWN (…)] result lists one entry per option arm, and after the
   normalisations above those entries are identical text.  Keeping them all
   would pin the number of arms in [Cvc5.options_l] -- the same churn the
   option-text normalisation exists to avoid -- so a run of identical adjacent
   entries collapses to one.  Entries are what the pretty-printer separates by
   a newline and a single space before a tag, [\n BACKEND_ERROR {]; message
   continuation lines are indented much further. *)
let re_entry = Str.regexp "\n \\([A-Z_]+ {\\)"

let rstrip s =
  let n = ref (String.length s) in
  while !n > 0 && (s.[!n - 1] = ' ' || s.[!n - 1] = '\n') do decr n done;
  String.sub s 0 !n

let rec dedup = function
  | a :: (b :: _ as tl) when a = b -> dedup tl
  | a :: tl -> a :: dedup tl
  | [] -> []

let collapse_repeated_entries s =
  (* the result list is the last thing on stdout, so it runs from the first
     "\n(" of the stdout half to the last ")" before the stderr separator *)
  match Str.search_forward (Str.regexp_string "--- stderr ---\n") s 0 with
  | exception Not_found -> s
  | cut -> (
    let stdout_part = String.sub s 0 cut in
    match
      ( Str.search_forward (Str.regexp_string "\n(") stdout_part 0,
        Str.search_backward (Str.regexp_string ")") stdout_part cut )
    with
    | exception Not_found -> s
    | first, last when last > first + 2 ->
      let body = String.sub stdout_part (first + 2) (last - first - 2) in
      let entries =
        Str.split_delim (Str.regexp "\000") (Str.global_replace re_entry "\000\\1" body)
        |> List.map rstrip
      in
      let kept = dedup entries in
      if List.length kept = List.length entries then s
      else
        String.sub s 0 (first + 2)
        ^ String.concat " \n " kept
        ^ String.sub s last (String.length s - last)
    | _ -> s)

let normalise s =
  let s = canonicalise re_unknown "?__%d" s in
  let s = canonicalise re_var "v%d" s in
  (* wall-clock time and the option arm that won the race are not properties
     of the answer; pinning them makes every unrelated edit a golden churn *)
  let s = Str.global_replace re_time "time:Ns" s in
  let s = Str.global_replace re_options "message=\"options: OPTIONS\"" s in
  collapse_repeated_entries s

(** {2 Running the child} *)

let read_file f =
  let ic = open_in_bin f in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  s

(* OCaml's signal numbers are its own, portable, and negative; a golden file
   should not carry [signal(-7)]. *)
let signal_name n =
  let known =
    [ (Sys.sigabrt, "SIGABRT"); (Sys.sigalrm, "SIGALRM"); (Sys.sigfpe, "SIGFPE");
      (Sys.sighup, "SIGHUP"); (Sys.sigill, "SIGILL"); (Sys.sigint, "SIGINT");
      (Sys.sigkill, "SIGKILL"); (Sys.sigpipe, "SIGPIPE");
      (Sys.sigquit, "SIGQUIT"); (Sys.sigsegv, "SIGSEGV");
      (Sys.sigterm, "SIGTERM"); (Sys.sigstop, "SIGSTOP") ]
  in
  match List.assoc_opt n known with
  | Some s -> s
  | None -> string_of_int n

let rec nap seconds =
  (* [select] returns early on a signal; a short sleep must not become a busy
     loop or a long one *)
  let t0 = Unix.gettimeofday () in
  try ignore (Unix.select [] [] [] seconds)
  with Unix.Unix_error (Unix.EINTR, _, _) ->
    let left = seconds -. (Unix.gettimeofday () -. t0) in
    if left > 0. then nap left

(* The child gets its own process group, so the deadline can take down the
   whole tree.  nunchaku spawns every backend through [/bin/sh -c], and a
   SIGKILL to nunchaku alone leaves those solvers running, reparented to init
   and burning a core for the rest of the job. *)
let spawn prog args fd_out fd_err =
  match Unix.fork () with
  | 0 ->
    (try ignore (Unix.setsid ()) with _ -> ());
    Unix.dup2 fd_out Unix.stdout;
    Unix.dup2 fd_err Unix.stderr;
    Unix.close fd_out;
    Unix.close fd_err;
    (try Unix.execv prog (Array.of_list (prog :: args))
     with _ -> Unix._exit 127)
  | pid -> pid

(* SIGTERM first so nunchaku can close its backends itself, SIGKILL if it will
   not; to the group either way. *)
let kill_group pid =
  let signal_group s = try Unix.kill (-pid) s with Unix.Unix_error _ -> () in
  let reaped () = fst (Unix.waitpid [ Unix.WNOHANG ] pid) <> 0 in
  signal_group Sys.sigterm;
  let grace = Unix.gettimeofday () +. 0.5 in
  let rec wait () =
    if not (reaped ()) then
      if Unix.gettimeofday () < grace then (nap 0.02; wait ())
      else (signal_group Sys.sigkill; ignore (Unix.waitpid [] pid))
  in
  wait ()

(* [Unix.waitpid [WNOHANG]] polled against a wall-clock deadline: the child is
   killed and reported as [timeout] rather than hanging the whole suite. *)
let run ~deadline prog args =
  let out = Filename.temp_file "run_case" ".out" in
  let err = Filename.temp_file "run_case" ".err" in
  Fun.protect
    ~finally:(fun () ->
       List.iter (fun f -> try Sys.remove f with Sys_error _ -> ()) [ out; err ])
    (fun () ->
       let fd_of f =
         Unix.openfile f [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CREAT ] 0o600
       in
       let fd_out = fd_of out and fd_err = fd_of err in
       let pid = spawn prog args fd_out fd_err in
       Unix.close fd_out;
       Unix.close fd_err;
       let give_up = Unix.gettimeofday () +. deadline in
       let rec poll () =
         match Unix.waitpid [ Unix.WNOHANG ] pid with
         | 0, _ ->
           if Unix.gettimeofday () > give_up then (kill_group pid; "rc=timeout")
           else (nap 0.01; poll ())
         | _, Unix.WEXITED n -> Printf.sprintf "rc=%d" n
         | _, (Unix.WSIGNALED n | Unix.WSTOPPED n) ->
           Printf.sprintf "rc=signal(%s)" (signal_name n)
       in
       let status = poll () in
       read_file out ^ "--- stderr ---\n" ^ read_file err ^ status ^ "\n")

(** {2 CLI} *)

let () =
  let prog = ref None and deadline = ref 30. and args = ref [] in
  let rec parse = function
    | [] -> usage ()
    | "--" :: rest -> args := rest
    | "--exe" :: p :: rest ->
      prog := Some p;
      parse rest
    | "--deadline" :: d :: rest ->
      deadline := float_of_string d;
      parse rest
    | "--setenv" :: assign :: rest ->
      (* VAR=VALUE in one word, so that an empty VALUE is expressible *)
      (match String.index_opt assign '=' with
       | None -> usage ()
       | Some i ->
         Unix.putenv (String.sub assign 0 i)
           (String.sub assign (i + 1) (String.length assign - i - 1)));
      parse rest
    | _ -> usage ()
  in
  parse (List.tl (Array.to_list Sys.argv));
  match !prog with
  | None -> usage ()
  | Some prog -> print_string (normalise (run ~deadline:!deadline prog !args))
