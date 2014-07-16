open Sys
open Unix
open Async.Std
(* compile with: 
ocamlfind ocamlopt -package bitstring,bitstring.syntax -syntax bitstring.syntax -linkpkg mqtt.ml -o mqtt
*)

let string_of_char c = String.make 1 c 

let msg_id = ref 0;

type bytes_char_t = { lsb: char; msb: char }

(* pass in an int and get two char string back *)
let int_to_str2 i = 
  (string_of_char (char_of_int ((i lsr 8) land 0xFF))) ^ 
  (string_of_char (char_of_int (i land 0xFF)))

(* 2 char string to int *)
let str2_to_int s = (((int_of_char s.[0]) lsl 8) land 0xFF00) lor 
                    ((int_of_char s.[1]) land 0xFF) 

let get_msg_id_bytes = 
  incr msg_id;
  int_to_str2 !msg_id

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

type packet_t = {
                   header: header_t;
                   topic:  string ;
                   msg_id: int;
                   payload: string option 
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

let charlist_to_str l =
  let len = List.length l in
  let res = String.create len in
  let rec imp i = function
  | [] -> res
  | c :: l -> res.[i] <- c; imp (i + 1) l in
  imp 0 l;; 


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
  printf "str_to_chrlist\n";
  List.rev (aux s []) 

let str_to_intlist s = List.map (fun c -> Char.code c) (str_to_charlist s)
  

let msg_header msg dup qos retain =
  char_of_int ((((msg_type_to_int msg) land 0xFF) lsl 4) lor
               ((if dup then 0x1 else 0x0) lsl        3) lor
               ((qos land 0x03) lsl                   1) lor
               (if retain then 0x1 else 0x0))


let get_header reader = 
  Reader.read_char reader 
  >>= function
      | `Eof  -> failwith "No header available!"
      | `Ok c -> let byte_1 = Char.code c in
      let mtype = match (int_to_msg_type ((byte_1 lsr 4) land 0xFF)) with 
      | None -> failwith "Not a legal msg type!"
      | Some msg -> msg in
      get_remaining_len reader >>=
      fun remaining_bytes -> 
      let dup   = if ((byte_1 lsr 3) land 0x01) = 1 then true else false in
      let qos   = (byte_1 lsr 1) land 0x3 in
      let retain= if (byte_1 land 0x01) = 1 then true else false in
      return { msg= mtype; dup= dup; qos= qos; retain= retain; 
               remaining_len= remaining_bytes; buffer="" }

(* try to read a packet from the broker *)
let receive_packet reader = 
  get_header reader 
  >>= fun header ->
      let buffer = String.create header.remaining_len in 
      Reader.really_read reader ~len:header.remaining_len buffer 
      >>= function  
      | `Eof _ -> return (Core.Std.Result.Error "Failed to receive packet: " )
      | `Ok -> header.buffer <- buffer; return (Core.Std.Result.Ok header) 

let send_puback w msg_idstr =
  let puback_str = charlist_to_str [
    (msg_header PUBACK false 0 false);  
    Char.chr 2;
      (* remaining length *)
  ] ^ msg_idstr in
   printf "Send PUBACK\n";
   Writer.write ~pos:0 ~len:(String.length puback_str) w puback_str ;
   Writer.flushed w 

let rec receive_packets reader writer = 
  receive_packet reader >>=
  function
  | Error _ -> return ()
  | Ok header -> (if header.msg = PUBLISH then
                  (
                     (* only concerned about PUBLISH packets for now*) 
                     (* get payload from the buffer *)
                      (printf "\nGot a PUBLISH packet back from server\n");
                     let msg_id_len = (if header.qos = 0 then 0 else 2) in
                     let topic_len = ( (Char.code header.buffer.[0]) lsl 8) lor 
                                     (0xFF land (Char.code header.buffer.[1])) in
                     let topic =   String.sub header.buffer 2 topic_len in

                     let msg_id = ( if header.qos = 0 then 0 
                                    else ((Char.code header.buffer.[topic_len+2]) lsl 8) lor
                                     (0xFF land (Char.code header.buffer.[topic_len+3])) ) in

                     let payload_len=header.remaining_len - topic_len - 2 - msg_id_len in
                     let payload = Some (String.sub header.buffer (topic_len + 2 + msg_id_len) payload_len) in
                     Pipe.write pw { header ; 
                                     topic ;
                                     msg_id;
                                     payload 
                                   } >>=
                     fun () -> send_puback writer (int_to_str2 msg_id)
                  )
                  else
                  (
                     printf "received non-PUBLISH msg from server\n";
                     (* TODO: implement QOS responses*)
                     return () )) 
                  >>= fun() -> receive_packets reader writer

(* process a PUBLISH packet received from broker 
   process_publish_pkt f 
   where topic, payload and msg_id are passed to f
*) 
let process_publish_pkt f = 
  let rec process' ()  =
	  Pipe.read pr >>=
	  function
	  | `Eof -> return ()
	  | `Ok pkt -> (*first send back PUBACK *) 
		       match pkt with 
		       | { payload = None; _ } -> return ()
		       | { topic = t; payload = Some p; msg_id = m; _ }  -> 
                         return (f t p m) >>=
                         fun () -> process' ()   in
  ignore( process' () : (unit Deferred.t) )

let receive_connack reader = 
  get_header reader 
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
    (msg_header PINGREQ false 0 false);  
    Char.chr 0  (* remaining length *)
  ] in
   Writer.write ~pos:0 ~len:(String.length ping_str) w ping_str ;
   Writer.flushed w 
   

let rec ping_loop w = 
  after (Core.Time.Span.of_sec 5.0) >>=
  fun () -> printf "Ping\n"; 
            send_ping_req w >>=  
            fun () -> ping_loop w 

let multi_byte_len len = 
  let rec aux bodylen acc = match bodylen with
  | 0 -> List.rev acc 
  | _ -> let bodylen' = bodylen/128 in
         let digit    = (bodylen mod 0x80) lor (if bodylen' > 0 then 0x80 else 0x00) in
         aux bodylen' (digit::acc) in
  aux len [] 

let subscribe topics w =
  let subscribe' = 
    let payload =  get_msg_id_bytes ^ 
                   List.fold_left 
                     (fun a b -> 
                             a^ (*accumulator*)
                             int_to_str2(String.length b)^ (* 2bytes for len*)
                             b ^ (* topic *)
                             string_of_char (char_of_int 1)  (* QOS fixed at 1*)
                     ) "" topics in
    let remaining_len = List.map (fun i -> char_of_int i) (multi_byte_len (String.length payload)) 
                        |> charlist_to_str in
    let subscribe_str = (string_of_char (msg_header SUBSCRIBE false 1 false)) ^ 
                        remaining_len ^
                        payload in
    Writer.write ~pos:0 ~len:(String.length subscribe_str) w subscribe_str;
    Writer.flushed w in
  ignore( subscribe' : ( unit Deferred.t))
  
let publish ?(dup=false) ?(qos=0) ?(retain=false) topic payload w =
  let msg_id_str = if qos > 0 then get_msg_id_bytes else "" in
  let topic_len_str = int_to_str2 (String.length topic) in
  let var_header = topic_len_str ^ topic ^ msg_id_str in
  let publish_str' = var_header ^ payload in
  let remaining_bytes = List.map (fun i -> char_of_int i) (multi_byte_len (String.length publish_str'))
                       |> charlist_to_str in
  let publish_str = (string_of_char (msg_header PUBLISH dup qos retain)) ^
                     remaining_bytes ^
                     publish_str' in
  Writer.write ~pos:0 ~len:(String.length publish_str) w publish_str;
  Writer.flushed w 


let connect_to_broker server_name port_num f =
  let connect_to_broker' () = 
    let connect_str = charlist_to_str [
      (msg_header CONNECT false 0 false); 
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
      ignore(receive_packets t.reader t.writer) ;(*>>=*)
      ignore (ping_loop t.writer) ;
      f t  ;
      fun () -> Writer.close t.writer >>|
      fun () -> Reader.close
    | Error errstr ->  
      failwith errstr in
  ignore(connect_to_broker' () )

   
