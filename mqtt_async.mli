open Sys
open Unix
open Async.Std

val keep_alive_timer_interval_default : float
val keepalive : int
val version : int
val msg_id : int ref
type t = { reader : Async_unix.Reader.t; writer : Async_unix.Writer.t; }
type msg_type =
    CONNECT
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
type header_t = {
  msg : msg_type;
  dup : bool;
  qos : int;
  retain : bool;
  remaining_len : int;
  mutable buffer : string;
}
type packet_t = {
  header : header_t;
  topic : string;
  msg_id : int;
  payload : string option;
}
val pr : packet_t Async.Std.Pipe.Reader.t
val pw : packet_t Async.Std.Pipe.Writer.t
val msg_type_to_int : msg_type -> int
val msg_type_to_str : msg_type -> string
val int_to_msg_type : int -> msg_type option
val get_remaining_len : Async_unix.Reader.t -> int Async_kernel.Deferred.t
val msg_header : msg_type -> bool -> int -> bool -> char
val get_header : Async_unix.Reader.t -> header_t Async_kernel.Deferred.t
val receive_packet :
  Async_unix.Reader.t ->
  (header_t, string) Core_kernel.Std_kernel._result Async_kernel.Deferred.t
val send_puback :
  Async_unix.Writer.t -> string -> unit Async_kernel.Deferred.t
val receive_packets :
  Async_unix.Reader.t -> Async_unix.Writer.t -> unit Async_kernel.Deferred.t
val process_publish_pkt : (string -> string -> int -> unit) -> unit
val receive_connack :
  Async_unix.Reader.t ->
  (string, string) Core_kernel.Std_kernel._result Async_kernel.Deferred.t
val connect : host:string -> port:int -> t Async_kernel.Deferred.t
val send_ping_req : Async_unix.Writer.t -> unit Async_kernel.Deferred.t
val ping_loop :
  ?interval:float -> Async_unix.Writer.t -> 'a Async_kernel.Deferred.t
val multi_byte_len : int -> int list
val subscribe : ?qos:int -> topics:string list -> Async_unix.Writer.t -> unit
val unsubscribe :
  ?qos:int -> topics:string list -> Async_unix.Writer.t -> unit
val publish :
  ?dup:bool ->
  ?qos:int ->
  ?retain:bool ->
  topic:string ->
  payload:string -> Async_unix.Writer.t -> unit Async_kernel.Deferred.t
val publish_periodically :
  ?qos:int ->
  ?period:float ->
  topic:string -> (unit -> string) -> Async_unix.Writer.t -> unit
val connect_to_broker :
  ?keep_alive_interval:float ->
  ?dup:bool ->
  ?qos:int ->
  ?retain:bool ->
  ?username:string ->
  ?password:string ->
  ?will_message:string ->
  ?will_topic:string ->
  ?clean_session:bool ->
  ?will_qos:int ->
  ?will_retain:bool -> broker:string -> port:int -> (t -> unit) -> unit
