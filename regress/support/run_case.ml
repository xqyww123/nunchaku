(* Test driver for the golden-file regression suites.

   Usage:
     run_case --exe PROG [--deadline SECONDS] [--setenv VAR=VALUE]... -- ARGS...

   It runs [PROG ARGS...] under a wall-clock deadline, capturing stdout and
   stderr separately, and writes one deterministic report to its own stdout:

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

let normalise s =
  let s = canonicalise re_unknown "?__%d" s in
  let s = canonicalise re_var "v%d" s in
  (* wall-clock time and the option arm that won the race are not properties
     of the answer; pinning them makes every unrelated edit a golden churn *)
  let s = Str.global_replace re_time "time:Ns" s in
  Str.global_replace re_options "message=\"options: OPTIONS\"" s

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

(* [Unix.waitpid [WNOHANG]] polled against a wall-clock deadline: the child is
   killed and reported as [timeout] rather than hanging the whole suite. *)
let run ~deadline prog args =
  let out = Filename.temp_file "run_case" ".out" in
  let err = Filename.temp_file "run_case" ".err" in
  let fd_of f =
    Unix.openfile f [ Unix.O_WRONLY; Unix.O_TRUNC; Unix.O_CREAT ] 0o600
  in
  let fd_out = fd_of out and fd_err = fd_of err in
  let pid =
    Unix.create_process prog (Array.of_list (prog :: args)) Unix.stdin fd_out
      fd_err
  in
  Unix.close fd_out;
  Unix.close fd_err;
  let give_up = Unix.gettimeofday () +. deadline in
  let rec poll () =
    match Unix.waitpid [ Unix.WNOHANG ] pid with
    | 0, _ ->
      if Unix.gettimeofday () > give_up then (
        Unix.kill pid Sys.sigkill;
        ignore (Unix.waitpid [] pid);
        "rc=timeout")
      else (
        ignore (Unix.select [] [] [] 0.01);
        poll ())
    | _, Unix.WEXITED n -> Printf.sprintf "rc=%d" n
    | _, (Unix.WSIGNALED n | Unix.WSTOPPED n) ->
      Printf.sprintf "rc=signal(%s)" (signal_name n)
  in
  let status = poll () in
  let report =
    read_file out ^ "--- stderr ---\n" ^ read_file err ^ status ^ "\n"
  in
  Sys.remove out;
  Sys.remove err;
  report

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
