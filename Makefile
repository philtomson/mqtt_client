all: oasis-setup configure build 

oasis-setup: 
				oasis setup

configure:	oasis-setup
				ocaml setup.ml -configure

build: setup.data 
				ocaml setup.ml -build

install: _build/mqtt_async.cmx
				ocaml setup.ml -install

reinstall: _build/mqtt_async.cmx
				ocaml setup.ml -reinstall

uninstall: 
				ocaml setup.ml -uninstall

clean: 
				ocaml setup.ml -clean
				rm -f setup.data setup.log 

scrub: clean
				ocaml setup.ml -distclean
				rm -rf _tags
				rm -rf myocamlbuild.ml
				rm -rf META
				rm -rf setup.ml
	
.PHONY: all clean setup configure install build
