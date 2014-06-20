open Sys;;
open Unix;;
(* compile with: 
ocamlfind ocamlopt -package bitstring,bitstring.syntax -syntax bitstring.syntax -linkpkg mqtt.ml -o mqtt
*)

let broker = "test.mosquitto.org"
(*let broker = "localhost"*)
let port   = 1883

type msg_type = CONNECT | CONNACK | PUBLISH | PUBACK | PUBREC | PUBREL | PUBCOMP |
                SUBSCRIBE | SUBACK | UNSUBSCRIBE | UNSUBACK | PINGREQ | PINGRESP |
                DISONNECT | RESERVED                 

let msg_type_to_int msg = match msg with
  CONNECT     -> 1
| CONNACK     -> 2
| PUBLISH     -> 3
| PUBACK      -> 4
| PUBREC      -> 5
| PUBREL      -> 6
| PUBCOMP     -> 7
| SUBSCRIBE   -> 8
| SUBACK      -> 9
| UNSUBSCRIBE -> 10
| UNSUBACK    -> 11
| PINGREQ     -> 12
| PINGRESP    -> 13
| DISONNECT   -> 14
| RESERVED    -> 15

let max_packet_size = 128 
let keepalive       = 15
let version         = 3


let  qOS0 =        (0 lsl 1)
let  qOS1 =        (1 lsl 1)
let  qOS2 =        (2 lsl 1)

let do_while f p ~init =
  let rec loop v =
    let v = f v in
    if p v then loop v
  in
  loop init

(*do_while (fun v ->
            let v = succ v in
            Printf.printf "%d\n" v;
            (v))
         (fun v -> v mod 6 <> 0)
         ~init:0 *)

type message = {   msg:        msg_type;
                   dup:        bool;
                   qos:        int;
                   retain:     bool;
                   payload:    string 
               }

let msg_header msg dup qos retain =
  (((msg_type_to_int msg) land 0xFF) lsl 4) lor
  ((if dup then 0x1 else 0x0) lsl        3) lor
  ((qos land 0x03) lsl                   1) lor
  (if retain then 0x1 else 0x0)

let rec str_to_charlist s = 
  let rec aux s lst = 
    let len = String.length s in
    match  len with
    0 -> lst
  | n -> (aux (String.sub s 1 (len-1)) (s.[0]::lst)) in
  List.rev (aux s []) 
  

let charlist_to_str l =
  let res = String.create (List.length l) in
  let rec imp i = function
  | [] -> res
  | c :: l -> res.[i] <- c; imp (i + 1) l in
  imp 0 l;; 

let packet = List.map (fun b -> Char.chr b) [0x10;0x23;0x0 ; 0x6; 0x4d; 0x51; 0x49; 0x73; 0x64; 0x70; 0x3; 0x2; 0x00; 0xf; 0x0; 0x15; 0x72; 0x75; 0x62; 0x79; 0x5f;0x38; 0x77; 0x33; 0x6a; 0x6d; 0x65; 0x72; 0x6d; 0x6e; 0x33; 0x6c; 0x36; 0x66 ;0x37; 0x33; 0x6a ] 

(*

*)

let receive_connack sock = 
  let buffer_size = 4096 in 
  let buffer = String.create buffer_size in 
  let bytes_back =  read sock buffer 0 4 in
  if (int_of_char buffer.[3]) != 0 then begin
    failwith "connection was not established\n"
  end;
  if (int_of_char buffer.[0]) != 0x20 then begin
    failwith "did not receive a CONNACK"
  end;
  bytes_back, buffer

let connect_to_broker server_name port_num f =
  let connect_str = charlist_to_str [
    char_of_int (msg_header CONNECT false 0 false); 
    Char.chr 19; (* should be 12 ?*)
    Char.chr 0x00; 
    Char.chr 0x06; 
    'M';'Q';'I';'s';'d';'p'; 
    Char.chr version; 
    Char.chr 0x00; (* connect flags  why was it CE?*)
    Char.chr 0x00; (* keep alive timer MSB*)
    Char.chr 0x0A;  (* keep alive timer LSB*)
    Char.chr 0x00; (* client ID len MSB *)
    Char.chr 0x05; (* client ID len LSB *)
    (* client id *)
    'o';'c';'a';'m';'l'
  ] in
  let _ = Printf.printf "connect_str length: %d \n" (String.length connect_str) in
  let server_addr =
    try (gethostbyname server_name).h_addr_list.(0)
    with Not_found ->
      prerr_endline (server_name ^ ": host not found");
      exit 2 in
  let sock = socket PF_INET SOCK_STREAM 0 in
  connect sock (ADDR_INET(server_addr, port_num));
  ignore (write sock connect_str 0 (String.length connect_str));
  let bytes_back,buffer = receive_connack sock in
  Printf.printf "Got %d bytes back\nFirst byte back is:%x\n" bytes_back (int_of_char buffer.[0]);
  Printf.printf "byte 4 back is:%x\n"  (int_of_char buffer.[3]);
  f sock ;
  close sock
   
let main () =  
   handle_unix_error connect_to_broker broker port (fun sock  ->
     Printf.printf "done\n"
   );; 

main () 

