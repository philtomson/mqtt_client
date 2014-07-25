(** test_mqtt.ml:
  * Example useage of Mqtt_async module
  * Subscribes to every topic (#) then waits for a message to 
  * topic "PING" which doesn't start with 'A' at which point it 
  * unsubscribes from topic and continues to send ping's to keep alive
*)
(* compile example code (test_mqtt.ml) with: 
  $ corebuild -pkg async,unix  mqtt_async.ml test_mqtt.native
*)

open Sys
open Async.Std
open Mqtt_async

(** get_temperature: fake temperature reading just for testing *)
let get_temperature () = 
  20.0 +. Random.float 1.0 

let run ~broker ~port () =  
   Pipe.set_size_budget pr 256 ;
   connect_to_broker ~will_topic:"lastwill" ~will_message:"goodbye cruel world"
   ~password:"password" ~username:"test"  ~broker ~port (fun t  ->
     process_publish_pkt ( fun topic payload msg_id -> 
                             printf "Topic: %s\n" topic;
                             printf "Payload: %s\n" payload;
                             printf "Msg_id is: %d\n" msg_id;
                             if topic = "PING" && payload.[0] <> 'A' then begin
                               ignore(publish ~qos:1 ~topic:"PING" ~payload:"A PONG to your PING!" t.writer)
                             end;
                             ignore(unsubscribe ~topics:["#"] t.writer)
(**)
                             
                          );
     printf "Start user section\n";
     subscribe ~topics:["#"] t.writer ;
     publish_periodically ~topic:"temperature" (fun () -> string_of_float(get_temperature ()) ) t.writer;
   ); 
   Deferred.never () 

let () = 
  Command.async_basic
    ~summary: "Subscribing to all messages (#)"
    Command.Spec.(
      empty
      +> flag "-broker" (optional_with_default "test.mosquitto.org" string)
         ~doc: "broker address (defaults to \"test.mosquitto.org\")"
      +> flag "-port"   (optional_with_default 1883 int)
         ~doc: "port (defaults to 1883)"
     )
     ( fun broker port () -> run ~broker ~port () )
  |> Command.run

