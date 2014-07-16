open Sys
open Async.Std
open Mqtt_async

let main () =  
   Pipe.set_size_budget pr 256 ;

   connect_to_broker broker port  (fun t  ->
     process_publish_pkt ( fun topic payload msg_id -> 
                             printf "Topic: %s\n" topic;
                             printf "Payload: %s\n" payload;
                             printf "Msg_id is: %d\n" msg_id;
                             if topic = "PING" && payload.[0] <> 'A' then
                               ignore(publish ~qos:1 "PING" "A PONG to your PING!" t.writer)
                             );
     printf "Start user section\n";
     subscribe ["#"] t.writer ;
     ignore(publish "TOPIC_42" "THE ANSWER TO LIFE, THE UNIVERSE AND EVERYTHING!!!" t.writer);
     printf "subscribed\n"
   );
   Core.Never_returns.never_returns (Scheduler.go ()) ;;

main ()
