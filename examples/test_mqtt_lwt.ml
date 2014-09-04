(** test_mqtt.ml:
  * Example useage of Mqtt_async module
  * Subscribes to every topic (#) then waits for a message to 
  * topic "PING" which doesn't start with 'A' at which point it 
  * unsubscribes from topic and continues to send ping's to keep alive
*)
(* compile example code (test_mqtt.ml) with: 
  $ corebuild -pkg async,unix  mqtt_async.ml test_mqtt.native
*)

open Lwt
open Mqtt_lwt
open Printf

(** get_temperature: fake temperature reading just for testing *)
let get_temperature () = 
  20.0 +. Random.float 1.0 


let run_client ~broker ~port () =  
  puts "Starting...\n" >>
  (*let open Connection in*)
   (*Pipe.set_size_budget pr 256 ;*)
   connect_to_broker ~will_topic:"lastwill" ~will_message:"goodbye cruel world"
   ~password:"password" ~username:"test"  ~broker ~port (fun conn  ->
     puts "Start user section\n" >>
     (* first subscribe *)
     (subscribe ~topics:["#"] conn.write_chan)  >> 
     (process_publish_pkt conn ( fun topic payload msg_id -> 
       puts (sprintf "Topic: %s\nPayload: %s\nMsg_id: %d\n" topic payload
             msg_id) >> 
             (if topic = "PING" && payload.[0] <> 'A' then (

                publish ~qos:1 ~topic:"PING" 
                   ~payload:"A PONG to your PING!"
                   conn.write_chan
              )
             else
               (*
                publish ~qos:1 ~topic:"PING" 
                   ~payload:"No Ping"
                   conn.write_chan
               *)
                return ()
             ) (*>>
             unsubscribe ~topics:["#"] conn.write_chan  
             *)
                             
     )) (**) <&>
     (publish_periodically ~topic:"temperature" (fun () ->
       string_of_float(get_temperature ()) ) conn.write_chan)
     
      
   ) 
   

let () = 
  Printf.printf "Starting... 1,,,2,,,3\n";
  Lwt_main.run ( run_client ~broker:"test.mosquitto.org" ~port:1883 () )
