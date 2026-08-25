(* A canned-reply fake solver, for hermetic backend tests.
   Prints the contents of the file named by FAKE_REPLIES, closes stdout, then
   drains stdin so the caller never blocks writing its problem.

   Closing stdout is what lets a reply end mid-token: the caller's lexer sees
   end of input, as it would from a solver that died, while this process stays
   alive to keep reading.  Data already written stays in the pipe.

   FAKE_ON_ARG makes the reply depend on how the caller invoked the solver:
   when it is set and that exact word is on this process' command line,
   FAKE_ON_ARG_REPLIES is printed instead of FAKE_REPLIES and the exit status
   is FAKE_ON_ARG_EXIT (default 0).  That is what lets a case pin a flag
   nunchaku must keep passing: the two replies are what the real solver
   answers with the flag and without it, so dropping the flag changes the
   case's golden. *)

let reply_file_ var =
  match Sys.getenv_opt var with
  | Some f -> f
  | None ->
    prerr_endline ("fake_solver: " ^ var ^ " is not set");
    exit 2

let () =
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore with _ -> ());
  let arg_given a = Array.exists (fun x -> x = a) Sys.argv in
  let file, status =
    match Sys.getenv_opt "FAKE_ON_ARG" with
    | Some a when arg_given a ->
      let status =
        match Sys.getenv_opt "FAKE_ON_ARG_EXIT" with
        | Some s -> int_of_string s
        | None -> 0
      in
      reply_file_ "FAKE_ON_ARG_REPLIES", status
    | _ -> reply_file_ "FAKE_REPLIES", 0
  in
  let ic = open_in_bin file in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  print_string s;
  flush stdout;
  close_out stdout;
  (try while true do ignore (input_char stdin) done with End_of_file -> ());
  (* stdout is already closed, so exit must not try to flush it again *)
  Unix._exit status
