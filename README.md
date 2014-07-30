MQTT client in OCaml using Core.Async

Current status: 

* publish
* subscribe
* unsubscribe
* pingreq (stayalive ping)

Dependencies:
* Core  (opam install core)
* Async (opam install async)
* Unix  (opam install base_unix)
* Threads (opam install base_threads)

To build library and test_mqtt.native example:
$ make

To install:
$ make install

To run:
$ test_mqtt.native [-port <port_num>] [-broker <broker address>]

(see: examples/test_mqtt.ml for example usage)


TODO:
* create OPAM package
* get working with mirage
