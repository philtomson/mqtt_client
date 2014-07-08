open Sys
open Unix
open Async.Std
(* compile with: 
ocamlfind ocamlopt -package bitstring,bitstring.syntax -syntax bitstring.syntax -linkpkg mqtt.ml -o mqtt
*)

type t = { 
    reader: Reader.t;
    writer: Writer.t;
    header_buffer: string
}

let header_length = 256 (* Adjust this! *)



let broker = "test.mosquitto.org"
(*let broker = "localhost"*)
let port   = 1883

type msg_type = CONNECT | CONNACK | PUBLISH | PUBACK | PUBREC | PUBREL | PUBCOMP |
                SUBSCRIBE | SUBACK | UNSUBSCRIBE | UNSUBACK | PINGREQ | PINGRESP |
                DISONNECT | RESERVED                 

type header_t = {    msg:            msg_type;
                     dup:            bool;
                     qos:            int;
                     retain:         bool;
                     remaining_len:  int;
                     mutable buffer: string;
               }

let (pr,pw) = Pipe.create ()

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

let int_to_msg_type b = match b with
  1 -> Some CONNECT 
| 2 -> Some CONNACK     
| 3 -> Some PUBLISH     
| 4 -> Some PUBACK      
| 5 -> Some PUBREC 
| 6 -> Some PUBREL
| 7 -> Some PUBCOMP    
| 8 -> Some SUBSCRIBE  
| 9 -> Some SUBACK      
| 10 -> Some UNSUBSCRIBE 
| 11 -> Some UNSUBACK   
| 12 -> Some PINGREQ    
| 13 -> Some PINGRESP    
| 14 -> Some DISONNECT   
| 15 -> Some RESERVED    
| _  -> None


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

let get_remaining_len reader =
  let rec aux multiplier value =
    Reader.read_char reader
    >>= function
        | `Eof -> return 0
        | `Ok c -> let digit = Char.code c in
                   match (digit land 128) with
                   | 0 ->  return (value + ((digit land 127) * multiplier))
                   | _ ->  aux (multiplier * 128) ( value + ((digit land 127) * multiplier)) in
    aux 1 0   



let  str_to_charlist s = 
  let rec aux s lst = 
    let len = String.length s in
    match  len with
    0 -> lst
  | _ -> (aux (String.sub s 1 (len-1)) (s.[0]::lst)) in
  List.rev (aux s []) 

let str_to_intlist s = List.map (fun c -> Char.code c) (str_to_charlist s)
  

let msg_header msg dup qos retain =
  (((msg_type_to_int msg) land 0xFF) lsl 4) lor
  ((if dup then 0x1 else 0x0) lsl        3) lor
  ((qos land 0x03) lsl                   1) lor
  (if retain then 0x1 else 0x0)


let deconstruct_header reader = 
  Reader.read_char reader 
  >>= function
      | `Eof  -> failwith "No header available!"
      | `Ok c -> let byte_1 = Char.code c in
      let mtype = match (int_to_msg_type ((byte_1 lsr 4) land 0xFF)) with 
      | None -> failwith "Not a legal msg type!"
      | Some msg -> msg in
      get_remaining_len reader
  >>= fun remaining_bytes -> 
      let dup   = if ((byte_1 lsr 3) land 0x01) = 1 then true else false in
      let qos   = (byte_1 lsr 1) land 0x3 in
      let retain= if (byte_1 land 0x01) = 1 then true else false in
      return { msg= mtype; dup= dup; qos= qos; retain= retain; 
               remaining_len= remaining_bytes; buffer="" }

(* try to read a packet from the broker *)
(* TODO:Also send keep-alive ping packets *)
let receive_packet reader = 
  deconstruct_header reader 
  >>= fun header ->
      let buffer = String.create header.remaining_len in 
      Reader.really_read reader ~len:header.remaining_len buffer 
      >>= function  
      | `Eof _ -> return (Core.Std.Result.Error "Failed to receive packet: " )
      | `Ok -> header.buffer <- buffer; return (Core.Std.Result.Ok header) 

let rec get_packets reader = 
  receive_packet reader >>=
  function
  | Error _ -> return ()
  | Ok header -> (if header.msg = PUBLISH then
                     (* only concerned about PUBLISH packets for now*) 
                     (Pipe.write pw header)
                  else
                     return () ) >>= fun() -> get_packets reader

let charlist_to_str l =
  let res = String.create (List.length l) in
  let rec imp i = function
  | [] -> res
  | c :: l -> res.[i] <- c; imp (i + 1) l in
  imp 0 l;; 

let packet = List.map (fun b -> Char.chr b) [0x10;0x23;0x0 ; 0x6; 0x4d; 0x51; 0x49; 0x73; 0x64; 0x70; 0x3; 0x2; 0x00; 0xf; 0x0; 0x15; 0x72; 0x75; 0x62; 0x79; 0x5f;0x38; 0x77; 0x33; 0x6a; 0x6d; 0x65; 0x72; 0x6d; 0x6e; 0x33; 0x6c; 0x36; 0x66 ;0x37; 0x33; 0x6a ] 

(*
let receive_connack sock = 
  let buffer_size = 4096 in 
  let buffer = String.create buffer_size in 
  let bytes_back =  read sock buffer 0 4 in
  if (int_of_char buffer.[0]) != 0x20 then begin
    failwith "did not receive a CONNACK"
  end;
  if (int_of_char buffer.[3]) != 0 then begin
    failwith "connection was not established\n"
  end;
  bytes_back, buffer
*)

let receive_connack reader = 
  deconstruct_header reader 
  >>= fun header ->
    if (header.msg <> CONNACK) then begin
      failwith "did not receive a CONNACK"
    end;
    let buffer = String.create header.remaining_len in 
    Reader.really_read reader ~len:header.remaining_len buffer 
    >>= function  
    | `Eof _ -> return (Core.Std.Result.Error "Failed to receive connack: " )
    | `Ok ->
      return 
      (if (int_of_char buffer.[header.remaining_len-1]) <> 0 then 
         (Core.Std.Result.Error "connection was not established\n")
      else
         (Core.Std.Result.Ok "connack received!") )

let connect ~host ~port = 
  Tcp.to_host_and_port host port
  |> Tcp.connect
  >>| fun (_,reader,writer) ->
    printf "Connect succeeded\n";
    { reader;
      writer;
      header_buffer=String.create header_length;
    }  

let send_ping_req w =
  let ping_str = charlist_to_str [
    char_of_int (msg_header PINGREQ false 0 false);  
    Char.chr 0  (* remaining length *)
  ] in
   (Writer.write ~pos:0 ~len:(String.length ping_str) w ping_str) 
  

let rec start_ping w = 
  after (Core.Time.Span.of_sec 5.0) >>>
  fun () -> printf "Ping\n"; 
            send_ping_req w; 
            start_ping w 


let connect_to_broker server_name port_num f =
  let connect_str = charlist_to_str [
    char_of_int (msg_header CONNECT false 0 false); 
    Char.chr 19; (* remaining length *)
    Char.chr 0x00; (* protocol length MSB *) 
    Char.chr 0x06; (* protocol length LSB *) 
    'M';'Q';'I';'s';'d';'p'; (* protocol *)
    Char.chr version; 
    Char.chr 0x00; (* connect flags  why was it CE?*)
    Char.chr 0x00; (* keep alive timer MSB*)
    Char.chr 0x0F;  (* keep alive timer LSB*)
    Char.chr 0x00; (* client ID len MSB *)
    Char.chr 0x05; (* client ID len LSB *)
    (* client id *)
    'o';'c';'a';'m';'l'
  ] in
  let _ = printf "connect_str length: %d \n" (String.length connect_str) in
  
  connect ~host:server_name ~port:port_num 
  >>= fun t -> 
  printf "Connected!\n";
  (Writer.write ~pos:0 ~len:(String.length connect_str) t.writer connect_str) ;
  printf "wait for connack...\n";
  receive_connack t.reader >>|
  function 
  | Ok pass_str  -> 
    printf "Ok: %s\n" pass_str ;
    ignore(get_packets t.reader) ;(*>>=*)
    start_ping t.writer ;  
    fun () -> f t  >>|
    fun () -> Writer.close t.writer >>|
    fun () -> Reader.close

  | Error errstr ->  
    failwith errstr 

   
let main () =  
   Pipe.set_size_budget pr 256 ;
   ignore(connect_to_broker broker port  (fun _  ->
     return (printf "done\n")
   ));
   Scheduler.go ()
   ;; 

main () 

