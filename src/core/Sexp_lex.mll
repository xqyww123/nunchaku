{
  type token =
    | ATOM of string
    | LIST_OPEN
    | LIST_CLOSE
    | EOI

  exception Error of Location.t * string

  let error lexbuf msg =
    let loc = Location.of_lexbuf lexbuf in
    raise (Error (loc,msg))
}

let newline = '\n' | "\r\n"
let white = [' ' '\r' '\t'] | newline

let comment_line = ';' [^ '\n']*
let printable_char = [^ '\n']

let num = ['0'-'9']
let letter = (['a'-'z'] | ['A'-'Z'])
let simple_symbol =
  (num | letter | '~' | '!' | '@' | '$' | '%' | '^' | '&' | '*' | '_' | '-' | '+' | '=' | '<' | '>' | '.' | '?' | '/')+

let invbars = '|' ([^ '\\' '|' '\n'] | '\\' '|')+ '|'

(* Body characters of an SMT-LIB 2.6 string literal: printable characters plus
   tab and carriage return.  Bytes >= 0x80 stay legal so that UTF-8 in a backend
   message does not abort the lexer; the other C0 controls and DEL do not, so an
   escape sequence smuggled through a backend error message cannot reach the
   user's terminal raw.  A newline is a branch of [string_body], not a member of
   this class, because it has to be counted. *)
let string_char = [' '-'!' '#'-'~' '\t' '\r' '\128'-'\255']

rule token = parse
  | comment_line { token lexbuf }
  | newline { Lexing.new_line lexbuf; token lexbuf }
  | white { token lexbuf }
  | eof { EOI }
  | '(' { LIST_OPEN }
  | ')' { LIST_CLOSE }
  | simple_symbol { ATOM (Lexing.lexeme lexbuf) }
  | invbars { ATOM (Lexing.lexeme lexbuf) }
  | '"' {
      (* An SMT-LIB string literal is scanned by a sub-rule rather than matched
         as one lexeme, so that [Lexing.new_line] runs on each newline inside it
         and an illegal byte is reported at its own position.  Restoring
         [lex_start_p] afterwards puts the opening quote back at the start of the
         token, so the literal's own location -- and the location of an
         unterminated one -- spans the whole literal. *)
      let start = lexbuf.Lexing.lex_start_p in
      let buf = Buffer.create 32 in
      Buffer.add_char buf '"';
      let s = string_body buf lexbuf in
      lexbuf.Lexing.lex_start_p <- start;
      match s with
        | Some s -> ATOM s
        | None -> error lexbuf "unterminated string literal"
    }
  | _ as c
    { let loc = Location.of_lexbuf lexbuf in
      raise (Error (loc, Printf.sprintf "lexing failed on char %c" c)) }

(* Body of a string literal; [buf] already holds the opening quote.  [None] is
   end of input before the closing quote -- the caller owns the position that
   error is reported at.  Branch order is irrelevant: ocamllex takes the longest
   match, so a doubled quote always wins over a single one. *)
and string_body buf = parse
  | "\"\"" { Buffer.add_string buf "\"\""; string_body buf lexbuf }
  | '"'    { Buffer.add_char buf '"'; Some (Buffer.contents buf) }
  | '\n'   { Buffer.add_char buf '\n'; Lexing.new_line lexbuf;
             string_body buf lexbuf }
  | string_char+ as s { Buffer.add_string buf s; string_body buf lexbuf }
  | eof    { None }
  | _ as c { error lexbuf
               (Printf.sprintf "illegal character 0x%02x in string literal"
                  (Char.code c)) }
