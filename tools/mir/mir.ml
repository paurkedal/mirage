(*
 * Copyright (c) 2010 Anil Madhavapeddy <anil@recoil.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *
 *)

(* Command line tool to build Mirage applications *)

open Arg 
open Printf

type os = Unix | Xen | Browser
type mode = Tree | Installed
type action = Build | Clean
type net = Static | DHCP

(* uname(3) bindings *)
external uname_os: unit -> string = "unix_sysname"
external uname_machine: unit -> string = "unix_sysmachine"

(* default arguments *)
let ocamldsort = ref "miragedsort.opt"
let ocamlopt = ref "ocamlopt.opt"
let ocamlopt_flags = "-nostdlib -annot"
let ocamljs_flags = "-nostdlib -annot"
let ocamljs_cclibs = ["primitives"; "support"; "console_stubs"; "clock_stubs"; "websocket_stubs"; "evtchn_stubs" ]
let ocamlopt_flags_extra = ref ""
let ocamldep = ref "ocamldep.opt"
let ocamljs = ref "ocamljs"
let cc = ref "gcc"
let os = ref Unix 
let mode = ref Tree
let net = ref DHCP
let action = ref Build
let modname = ref "app_main.t"

let set_key k fn f =
  let x = fn (String.lowercase f) in
  k := x

let set_os = set_key os 
  (function
   | "xen"|"x" -> Xen
   | "unix"|"u" -> Unix
   | "browser"|"b" -> Browser
   | f -> failwith (sprintf "Unknown -os '%s', needs to be unix|xen|browser" f)
  )

let set_mode = set_key mode
  (function
   | "tree"|"t" -> Tree
   | "installed"|"i" -> Installed
   | f -> failwith (sprintf "Unknown -mode '%s', needs to be tree|installed" f)
  )

let set_net = set_key net
  (function
   | "dhcp"|"d" -> DHCP
   | "static"|"s" -> Static
   | f -> failwith (sprintf "Unknown -net '%s', needs to be dhcp|static" f)
  )

let set_action = set_key action
  (function
   | "build"|"b" -> Build
   | "clean"|"c" -> Clean
   | f -> failwith (sprintf "Unknown -action '%s', needs to be build|clean" f)
  )

let set_var k r s = ("-" ^ k), Set_string r, (sprintf "%s (default: %s)" s !r)

let usage_str = sprintf "Usage: %s [options] <build dir>" Sys.argv.(0)

let cmd xs =
  let x = String.concat " " xs in
  let xcol = String.concat " " (("\027[36m" ^ (List.hd xs) ^ "\027[0m") :: (List.tl xs)) in
  eprintf "%s\n" xcol;
  match Sys.command x with 
  | 0 -> () 
  | n -> 
      eprintf "%s (exit %d)\n" x n; exit n

let _ =
  let target = ref None in
  let keyspec = [
      "-os", String set_os, "Set target operating system [xen|unix|browser]";
      "-mode", String set_mode, "Set where to build application [tree|installed]";
      "-net", String set_net, "How to configure network interfaces [dhcp|static]";
      "-action", String set_action, "Action to perform [build|clean]";
      set_var "mod" modname "Application module name";
      set_var "cc" cc "Compiler to use";
      set_var "ocamldsort" ocamldsort "ocamldsort binary";
      set_var "ocamlopt" ocamlopt "ocamlopt binary";
      set_var "ocamljs" ocamlopt "ocamljs binary";
      set_var "ocamlopt_flags" ocamlopt_flags_extra "ocamlopt flags";
      set_var "ocamldep" ocamldep "ocamldep binary";
    ] in
  parse keyspec (fun s -> target := Some s) usage_str;
  let mirage_root = match !mode with
    | Tree -> sprintf "%s/_build" (Sys.getcwd ())
    | Installed -> failwith "Installed mode not supported yet"
  in
  (* The target path/name *)
  let target = match !target with
   | None -> eprintf "No target specified\n"; Arg.usage keyspec usage_str; exit 1
   | Some x -> x in
  let build_dir =
    let i = String.rindex target '/' in
    String.sub target 0 i in

  match !action with
  | Clean ->
      cmd [ "rm -f *.cma *.cmi *.cmx *.a *.o *.annot mirage-unix mirage-os mirage-os.gz app.js app.html" ];
  | Build -> begin
 
      (* Start OS-specific build *)
      match !os with
      | Xen ->
          (* Build the raw application object file *)
          cmd [ "ocamlbuild"; "-Xs"; "tools,runtime,syntax"; sprintf "%s.o" target ];
          (* Relink sections for custom memory layout *)
          cmd [ sprintf "objcopy --rename-section .data=.mldata --rename-section .rodata=.mlrodata --rename-section .text=.mltext %s.o %s/-xen.o" target target ];
          (* Change to the Xen kernel build dir and perform build *)
          let runtime = sprintf "%s/runtime/xen" mirage_root in
          Sys.chdir (runtime ^ "/kernel");
          let app_lib = sprintf "APP_LIB=\"%s/%s-xen.o\"" mirage_root target in
          cmd [ "make"; app_lib ];
          let output_gz = sprintf "%s/kernel/obj/mirage-os.gz" runtime in
          let target_gz = sprintf "%s/mirage-os.gz" build_dir in
          let target_nongz = sprintf "%s/mirage-os" build_dir in
          (* Move the output kernel to the application build directory *)
          cmd [ "mv"; output_gz; target_gz ];
          (* Make an uncompressed version available for debugging purposes *)
          cmd [ "zcat"; target_gz; ">"; target_nongz ]

      | Unix -> 
          (* Build the raw application object file *)
          cmd [ "ocamlbuild"; "-Xs"; "tools,runtime,syntax"; sprintf "%s.o" target ];
          (* Change the the Unix kernel build dir and perform build *)
          let runtime = sprintf "%s/runtime/unix" mirage_root in
          Sys.chdir (runtime ^ "/main");
          let app_lib = sprintf "APP_LIB=\"%s/%s.o\"" mirage_root target in
          cmd [ "make"; app_lib ];
          let output_bin = sprintf "%s/main/app" runtime in
          let target_bin = sprintf "%s/mirage-unix" build_dir in
          cmd [ "mv"; output_bin; target_bin ]

      | Browser ->
          let runtime = sprintf "%s/runtime/browser" mirage_root in
          let console_html = sprintf "%s/app.html" runtime in

          let cclibs = String.concat " " (List.map (fun x -> sprintf "-cclib %s/%s.js" runtime x) ocamljs_cclibs) in
          (* Build the raw application object file *)
          cmd [ "ocamlbuild"; "-Xs"; "tools,runtime,syntax"; cclibs; sprintf "%s.js" target ];
          (* Copy in the console HTML *)
          cmd [ "mv"; sprintf "%s.js" target; build_dir ];
          cmd [ "cp"; console_html; build_dir ]
    end
