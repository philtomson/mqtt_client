(** mqtt_async.ml: MQTT client library written in OCaml 
 * Based on spec at: 
 * http://public.dhe.ibm.com/software/dw/webservices/ws-mqtt/mqtt-v3r1.html  
 * *)
open Sys
open Unix
open Async.Std
(* compile example code (test_mqtt.ml) with: 
  $ corebuild -pkg async,unix  mqtt_async.ml test_mqtt.native
*)

(* constants *)
let keep_alive_timer_interval_default = 10.0  (*seconds*)
let keepalive       = 15                      (*seconds*)
let version         = 3                (* MQTT version *)

let msg_id = ref 0

(* "private" Helper funcs *)
(** int_to_str2:  pass in an int and get a two-char string back *)
let string_of_char c = String.make 1 c 

let print_str str = 
  String.iter (fun c -> printf "0x%x -> %c, " (int_of_char c) c) str

(** int_to_str2: integer (up to 65535) to 2 byte encoded string *)
(* TODO: should probably throw exception if i is greater than 65535 *)
let int_to_str2 i = 
  (string_of_char (char_of_int ((i lsr 8) land 0xFF))) ^ 
  (string_of_char (char_of_int (i land 0xFF)))

(** encode_string: Given a string returns two-byte length follwed by string *)
let encode_string str = 
  (int_to_str2 (String.length str)) ^ str

(** str2_to_int: 2 char string to int *)
let str2_to_int s = (((int_of_char s.[0]) lsl 8) land 0xFF00) lor 
                    ((int_of_char s.[1]) land 0xFF) 

(** increment the current msg_id and return it as a 2 byte string *)
let get_msg_id_bytes = 
  incr msg_id;
  int_to_str2 !msg_id

let charlist_to_str l =
  let len = List.length l in
  let res = String.create len in
  let rec imp i = function
  | [] -> res
  | c :: l -> res.[i] <- c; imp (i + 1) l in
  imp 0 l;; 

let str_to_charlist s = 
  let rec aux s lst = 
    let len = String.length s in
    match  len with
      0 -> lst
    | _ -> (aux (String.sub s 1 (len-1)) (s.[0]::lst)) in
  printf "str_to_chrlist\n";
  List.rev (aux s []) 

let str_to_intlist s = List.map (fun c -> Char.code c) (str_to_charlist s)
(* end of "private" helper funcs *)

type t = { 
    reader: Reader.t;
    writer: Writer.t;
}

type msg_type = CONNECT 
              | CONNACK 
              | PUBLISH 
              | PUBACK 
              | PUBREC 
              | PUBREL 
              | PUBCOMP 
              | SUBSCRIBE 
              | SUBACK 
              | UNSUBSCRIBE 
              | UNSUBACK 
              | PINGREQ 
              | PINGRESP 
              | DISONNECT 
              | RESERVED                 

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

let msg_type_to_str msg = match msg with
  CONNECT     -> "CONNECT"
| CONNACK     -> "CONNACK"
| PUBLISH     -> "PUBLISH"
| PUBACK      -> "PUBACK"
| PUBREC      -> "PUBREC"
| PUBREL      -> "PUBREL"
| PUBCOMP     -> "PUBCOMP"
| SUBSCRIBE   -> "SUBSCRIBE"
| SUBACK      -> "SUBACK"
| UNSUBSCRIBE -> "UNSUBSCRIBE"
| UNSUBACK    -> "UNSUBACK"
| PINGREQ     -> "PINGREQ"
| PINGRESP    -> "PINGRESP"
| DISONNECT   -> "DISCONNECT"
| RESERVED    -> "RESERVED"

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

(* get_remaining_len: find the number of remaining bytes needed 
 * for this packet *)
let get_remaining_len reader =
  let rec aux multiplier value =
    Reader.read_char reader
    >>= function
        | `Eof -> return 0
        | `Ok c -> let digit = Char.code c in
                   match (digit land 128) with
                   | 0 ->  return (value + ((digit land 127) * multiplier))
                   | _ ->  aux (multiplier * 128) ( value + ((digit land 127)* 
                               multiplier)) in
    aux 1 0   


  
let msg_header msg dup qos retain =
  char_of_int ((((msg_type_to_int msg) land 0xFF) lsl 4) lor
               ((if dup then 0x1 else 0x0)        lsl 3) lor
               ((qos land 0x03)                   lsl 1) lor
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
  | Core.Std.Result.Error _ -> return ()
  | Core.Std.Result.Ok header -> 
      (match header.msg with  
       | PUBLISH ->
         (
         (* only concerned about PUBLISH packets for now*) 
         (* get payload from the buffer *)
         (printf "\nGot a PUBLISH packet back from server\n");
         let msg_id_len = (if header.qos = 0 then 0 else 2) in
         let topic_len = ( (Char.code header.buffer.[0]) lsl 8) lor 
                         (0xFF land (Char.code header.buffer.[1])) in
         let topic =  String.sub header.buffer 2 topic_len in
         let msg_id = 
           ( if header.qos = 0 then 0 
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
       | _ ->
         (
         printf "received %s msg from server\n" (msg_type_to_str header.msg);
         (* TODO: implement QOS responses*)
         return () )
         ) 
       >>= fun() -> receive_packets reader writer

(** process_publish_pkt f: 
  *  when a PUBLISH packet is received back from the broker, call the 
  *  passed-in function f with topic, payload and message id. 
  *  User supplies the function f which will process the publish packet
  *  as the user sees fit. This function is called asynchronously whenever
  *  a PUBLISH packet is received.
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

(** recieve_connack: wait for the CONNACT (Connection achnowledgement packet) 
*)
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

(** connect: estabishes the Tcp socket connection to the broker *)
let connect ~host ~port = 
  Tcp.to_host_and_port host port
  |> Tcp.connect
  >>| fun (_,reader,writer) ->
    printf "Connect succeeded\n";
    { reader;
      writer;
    }  

(** send_ping_req: sents a PINGREQ packet to the broker to keep 
 * the connetioon alive 
 *)
let send_ping_req w =
  let ping_str = charlist_to_str [
    (msg_header PINGREQ false 0 false);  
    Char.chr 0  (* remaining length *)
  ] in
   Writer.write ~pos:0 ~len:(String.length ping_str) w ping_str ;
   Writer.flushed w 
   
(** ping_loop: send a PINGREQ at regular intervals *)
let rec ping_loop ?(interval=keep_alive_timer_interval_default) w = 
  after (Core.Time.Span.of_sec interval) >>=
  fun () -> printf "Ping\n"; 
            send_ping_req w >>=  
            fun () -> ping_loop w 

(** multi_byte_len: The algorithm for encoding a decimal number into the 
 * variable length encoding scheme (see section 2.1 of MQTT spec
 *)
let multi_byte_len len = 
  let rec aux bodylen acc = match bodylen with
  | 0 -> List.rev acc 
  | _ -> let bodylen' = bodylen/128 in
         let digit    = (bodylen mod 0x80) lor (if bodylen' > 0 then 0x80 else 0x00) in
         aux bodylen' (digit::acc) in
  aux len [] 

(** subscribe to topics *)
let subscribe ?(qos=1) ~topics w =
  let subscribe' = 
    let payload =  
      (if qos > 0 then get_msg_id_bytes else "") ^ 
      List.fold_left 
        (fun a topic -> 
          a^ (*accumulator*)
          (encode_string topic) ^
	  string_of_char (char_of_int qos)  
        ) "" topics in
    let remaining_len = List.map (fun i -> char_of_int i) (multi_byte_len (String.length payload)) 
                        |> charlist_to_str in
    let subscribe_str = (string_of_char (msg_header SUBSCRIBE false 1 false)) ^ 
                        remaining_len ^
                        payload in
    Writer.write ~pos:0 ~len:(String.length subscribe_str) w subscribe_str;
    Writer.flushed w in
  ignore( subscribe' : ( unit Deferred.t))

(* TODO unsubscribe and subscribe are almost exactly identical. Refactor *)
let unsubscribe ?(qos=1) ~topics w =
  let unsubscribe' = 
    let payload =  
      (if qos > 0 then get_msg_id_bytes else "") ^ 
      List.fold_left 
      (fun a topic -> 
        a^ (*accumulator*)
        encode_string topic
      ) "" topics in
    let remaining_len = 
      List.map (fun i -> char_of_int i) (multi_byte_len (String.length payload)) 
      |> charlist_to_str in
    let unsubscribe_str = 
      (string_of_char (msg_header UNSUBSCRIBE false 1 false)) ^ 
      remaining_len ^
      payload in
    Writer.write ~pos:0 ~len:(String.length unsubscribe_str) w unsubscribe_str;
    Writer.flushed w in
  ignore( unsubscribe' : ( unit Deferred.t))
  
(** publish message to topic *)
let publish ?(dup=false) ?(qos=0) ?(retain=false) ~topic ~payload w =
  let msg_id_str = if qos > 0 then get_msg_id_bytes else "" in
  let var_header = (encode_string topic) ^ msg_id_str in
  let publish_str' = var_header ^ payload in
  let remaining_bytes = List.map (fun i -> char_of_int i) (multi_byte_len (String.length publish_str'))
                       |> charlist_to_str in
  let publish_str = (string_of_char (msg_header PUBLISH dup qos retain)) ^
                     remaining_bytes ^
                     publish_str' in
  Writer.write ~pos:0 ~len:(String.length publish_str) w publish_str;
  Writer.flushed w 

(** publish_periodically: periodically publish a message to 
 * a topic, period specified by period in seconds (float)
*)
let publish_periodically ?(qos=0) ?(period=1.0) ~topic f w =
  let rec publish_periodically' () =
    let pub_str = f () in
    after (Core.Time.Span.of_sec period) >>=
    fun () -> publish ~qos ~topic ~payload:pub_str w >>=
    fun () -> publish_periodically' () in
  ignore(publish_periodically' () : (unit Deferred.t) )

(** connect_to_broker *)
let connect_to_broker ?(keep_alive_interval=keep_alive_timer_interval_default) 
  ?(dup=false) ?(qos=0) ?(retain=false) ?(username="") ?(password="")
  ?(will_message="") ?(will_topic="") ?(clean_session=true) ?(will_qos=0) 
  ?(will_retain=false) ~broker ~port f =
  let _ = printf "will_topic is: %s\n" will_topic in 
  let connect_flags = 
    ((if clean_session then 0x02 else 0) lor
    (if (String.length will_topic ) > 0 then 0x04 else 0) lor
    ((will_qos land 0x03) lsl 3) lor
    (if will_retain then 0x20 else 0) lor
    (if (String.length password) > 0 then 0x40 else 0) lor
    (if (String.length username) > 0 then 0x80 else 0)) in    
(* keepalive timer, adding 1 below just to make the interval 1 sec longer than
   the ping_loop for safety sake *)
  let ka_timer_str = int_to_str2( int_of_float keep_alive_interval+1) in
  let variable_header = (encode_string "MQIsdp") ^ 
                        (string_of_char (char_of_int version)) ^
                        (string_of_char (char_of_int connect_flags)) ^
                        ka_timer_str in
  (* clientid string should be no longer that 23 chars *)
  let clientid = "OCaml_"^
    String.sub (Core.Std.Uuid.to_string (Core.Std.Uuid.create () )) 0 17 in
  let payload = 
    (encode_string clientid) ^
    (if (String.length will_topic)> 0 then encode_string will_topic else "")^
    (if (String.length will_message)>0 then encode_string will_message else "")^
    (if (String.length username) >0 then encode_string username else "") ^
    (if (String.length password) >0 then encode_string password else "") in
  let vheader_payload = variable_header ^ payload in
  let remaining_len = (multi_byte_len (String.length vheader_payload) ) 
                      |> List.map (fun i -> char_of_int i) 
                      |> charlist_to_str in
  let _ = printf "payload is:%s\n" payload in
  let connect_to_broker' () = 
    let connect_str = (string_of_char (msg_header CONNECT dup qos retain)) ^
                      remaining_len ^ 
                      vheader_payload in
    let _ = printf ">> connect_str length: %d \n" (String.length connect_str) in
    let _ = printf ">> connect_str is: %s \n" connect_str in
    let _ = printf ">> connect_flags is: %x\n" connect_flags in
    let _ = printf ">> payload is:%s\n" payload in
    let _ = print_str connect_str in
    connect ~host:broker ~port:port
    >>= fun t -> 
    printf "Connected!\n";
    (Writer.write ~pos:0 ~len:(String.length connect_str) t.writer connect_str) ;
    printf "Wait for CONNACK...\n";
    receive_connack t.reader >>|
    function 
    | Core.Std.Result.Ok pass_str  -> 
      printf "Ok: %s\n" pass_str ;
      ignore(receive_packets t.reader t.writer) ;(*>>=*)
      ignore (ping_loop ~interval:keep_alive_interval t.writer) ;
      f t  ;
      fun () -> Writer.close t.writer >>|
      fun () -> Reader.close
    | Core.Std.Result.Error errstr ->  
      failwith errstr in
  ignore(connect_to_broker' () )

