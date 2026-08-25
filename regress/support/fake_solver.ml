(* A canned-reply fake solver, for hermetic backend tests.
   Prints the contents of the file named by FAKE_REPLIES, closes stdout, then
   drains stdin so the caller never blocks writing its problem.

   Closing stdout is what lets a reply end mid-token: the caller's lexer sees
   end of input, as it would from a solver that died, while this process stays
   alive to keep reading.  Data already written stays in the pipe. *)
let () =
  (try Sys.set_signal Sys.sigpipe Sys.Signal_ignore with _ -> ());
  let file =
    match Sys.getenv_opt "FAKE_REPLIES" with
    | Some f -> f
    | None ->
      prerr_endline "fake_solver: FAKE_REPLIES is not set";
      exit 2
  in
  let ic = open_in_bin file in
  let s = really_input_string ic (in_channel_length ic) in
  close_in ic;
  print_string s;
  flush stdout;
  close_out stdout;
  (try while true do ignore (input_char stdin) done with End_of_file -> ())
