(*
 * Copyright (c) 2013 Thomas Gazagnaire <thomas@gazagnaire.org>
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
 *)

let version () =
  Printf.printf "%s\n%!" Path_generated.project_version;
  exit 0

let conf_file, xen =
  let xen = ref false in
  let usage_msg = "Usage: ocaml mirari.ml <conf-file>" in
  let file = ref None in
  let anon_fun f = match !file with
    | None   -> file := Some f
    | Some _ ->
      Printf.eprintf "%s\n" usage_msg;
      exit 1 in
  let specs = Arg.align [
      "--xen"    , Arg.Set xen     , " Generate xen image.";
      "--version", Arg.Unit version, " Display version information.";
    ] in
  Arg.parse specs anon_fun usage_msg;
  match !file with
  | None  ->
    Printf.eprintf "%s\n" usage_msg;
    exit 1
  | Some f -> f, !xen

let conf_dir = Filename.dirname conf_file
let conf_name = Filename.chop_extension (Filename.basename conf_file)

let lines_of_file file =
  let ic = open_in file in
  let lines = ref [] in
  let rec aux () =
    let line =
      try Some (input_line ic)
      with _ -> None in
    match line with
    | None   -> ()
    | Some l ->
      lines := l :: !lines;
      aux () in
  aux ();
  close_in ic;
  List.rev !lines

let strip str =
  let p = ref 0 in
  let l = String.length str in
  let fn = function
    | ' ' | '\t' | '\r' | '\n' -> true
    | _ -> false in
  while !p < l && fn (String.unsafe_get str !p) do
    incr p;
  done;
  let p = !p in
  let l = ref (l - 1) in
  while !l >= p && fn (String.unsafe_get str !l) do
    decr l;
  done;
  String.sub str p (!l - p + 1)

let cut_at s sep =
  try
    let i = String.index s sep in
    let name = String.sub s 0 i in
    let version = String.sub s (i+1) (String.length s - i - 1) in
    Some (name, version)
  with _ ->
    None

let split s sep =
  let rec aux acc r =
    match cut_at r sep with
    | None       -> List.rev (r :: acc)
    | Some (h,t) -> aux (strip h :: acc) t in
  aux [] s

let key_value line =
  match cut_at line ':' with
  | None       -> None
  | Some (k,v) -> Some (k, strip v)

let filter_map f l =
  let rec loop accu = function
    | []     -> List.rev accu
    | h :: t ->
        match f h with
        | None   -> loop accu t
        | Some x -> loop (x::accu) t in
  loop [] l

let subcommand ~prefix (command, value) =
  let p1 = String.uncapitalize prefix in
  match cut_at command '-' with
  | None      -> None
  | Some(p,n) ->
    let p2 = String.uncapitalize p in
    if p1 = p2 then
      Some (n, value)
    else
      None

let remove file =
  if Sys.file_exists file then
    Sys.remove file

let append oc fmt =
  Printf.kprintf (fun str ->
    Printf.fprintf oc "%s\n" str
  ) fmt

let newline oc =
  append oc ""

let error fmt =
  Printf.kprintf (fun str ->
    Printf.eprintf "ERROR: %s\n%!" str;
    exit 1;
  ) fmt

let info fmt =
  Printf.kprintf (Printf.printf "%s\n%!") fmt

let command fmt =
  Printf.kprintf (fun str ->
    match Sys.command str with
    | 0 -> ()
    | i -> error "The command %S exited with code %d." str i
  ) fmt

(* Headers *)
module Headers = struct

  let output oc =
    append oc "(* Generated by mirari *)";
    newline oc

end

(* Filesystem *)
module FS = struct

  type fs = {
    name: string;
    path: string;
  }

  type t = fs list

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"fs") kvs in
    let aux (name, path) = { name; path } in
    List.map aux kvs

  let call t =
    List.iter (fun {name; path} ->
      let path = Printf.sprintf "%s/%s" conf_dir path in
      let file = Printf.sprintf "%s/filesystem_%s.ml" conf_dir name in
      if Sys.file_exists path then (
        info "Creating %s." file;
        command "mir-crunch -name %S %s > %s\n" name path file
      ) else
      error "The directory %s does not exist." path
    ) t

  let output oc t =
    List.iter (fun { name; _ } ->
      append oc "open Filesystem_%s" name
    ) t;
    newline oc

end

(* IP *)
module IP = struct

  type ipv4 = {
    address: string;
    netmask: string;
    gateway: string;
  }

  type t =
    | DHCP
    | IPv4 of ipv4

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"ip") kvs in
    let use_dhcp =
      try List.assoc "use-dhcp" kvs = "true"
      with _ -> false in
    if use_dhcp then
      DHCP
    else
      let address =
        try List.assoc "address" kvs
        with _ -> "10.0.0.2" in
      let netmask =
        try List.assoc "netmask" kvs
        with _ -> "255.255.255.0" in
      let gateway =
        try List.assoc "gateway" kvs
        with _ -> "10.0.0.1" in
      IPv4 { address; netmask; gateway }

    let output oc = function
      | DHCP   -> append oc "let ip = `DHCP"
      | IPv4 i ->
        append oc "let get = function Some x -> x | None -> failwith \"Bad IP!\"";
        append oc "let ip = `IPv4 (";
        append oc "  get (Net.Nettypes.ipv4_addr_of_string %S)," i.address;
        append oc "  get (Net.Nettypes.ipv4_addr_of_string %S)," i.netmask;
        append oc "  [get (Net.Nettypes.ipv4_addr_of_string %S)]" i.gateway;
        append oc ")";
        newline oc

end

(* HTTP listening parameters *)
module HTTP = struct

  type http = {
    port   : int;
    address: string option;
  }

  type t = http option

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"http") kvs in
    if List.mem_assoc "port" kvs &&
       List.mem_assoc "address" kvs then
      let port = List.assoc "port" kvs in
      let address = List.assoc "address" kvs in
      let port =
        try int_of_string port
        with _ -> error "%S s not a valid port number." port in
      let address = match address with
        | "*" -> None
        | a   -> Some a in
      Some { port; address }
    else
      None

  let output oc = function
    | None   -> ()
    | Some t ->
      append oc "let listen_port = %d" t.port;
      begin
        match t.address with
        | None   -> append oc "let listen_address = None"
        | Some a -> append oc "let listen_address = Net.Nettypes.ipv4_addr_of_string %S" a;
      end;
      newline oc

end

(* Main function *)
module Main = struct

  type t =
    | IP of string
    | HTTP of string

  let create kvs =
    let kvs = filter_map (subcommand ~prefix:"main") kvs in
    let is_http = List.mem_assoc "http" kvs in
    let is_ip = List.mem_assoc "ip" kvs in
    match is_http, is_ip with
    | false, false -> error "No main function is specified. You need to add 'main-ip: <NAME>' or 'main-http: <NAME>'."
    | true , false -> HTTP (List.assoc "http" kvs)
    | false, true  -> IP (List.assoc "ip" kvs)
    | true , true  -> error "Too many main functions."

  let output_http oc main =
    append oc "let main () =";
    append oc "  let spec = Cohttp_lwt_mirage.Server.({";
    append oc "    callback    = %s;" main;
    append oc "    conn_closed = (fun _ () -> ());";
    append oc "  }) in";
    append oc "  Net.Manager.create (fun mgr interface id ->";
    append oc "    Printf.eprintf \"listening to HTTP on port %%d\\\\n\" listen_port;";
    append oc "    Net.Manager.configure interface ip >>";
    append oc "    Cohttp_lwt_mirage.listen mgr (listen_address, listen_port) spec";
    append oc "  )"

  let output_ip oc main =
    append oc "let main () =";
    append oc "  Net.Manager.create (fun mgr interface id ->";
    append oc "    Net.Manager.configure interface ip >>";
    append oc "    %s mgr interface id" main;
    append oc "  )"

  let output oc t =
    begin
      match t with
      | IP main   -> output_ip oc main
      | HTTP main -> output_http oc main
    end;
    newline oc;
    append oc "let () = OS.Main.run (main ())";

end

(* .obuild file *)
module OBuild = struct

  type t = string list

  let create kvs =
    let kvs = List.filter (fun (k,_) -> k = "depends") kvs in
    List.fold_left (fun accu (_,v) ->
      split v ',' @ accu
    ) [] kvs

  let output oc t =
    let file = Printf.sprintf "%s/main.obuild" conf_dir in
    let deps = match t with
      | [] -> ""
      | _  -> ", " ^ String.concat ", " t in
    let oc = open_out file in
    append oc "obuild-ver: 1";
    append oc "name: %s" conf_name;
    append oc "version: 0.0.0";
    newline oc;
    append oc "executable %s" conf_name;
    append oc "  main: main.ml";
    append oc "  buildDepends: mirage%s" deps;
    append oc "  pp: camlp4o";
    close_out oc

end

type t = {
  name: string;
  filename: string;
  fs: FS.t;
  ip: IP.t;
  http: HTTP.t;
  main: Main.t;
  depends: OBuild.t;
}

let create kvs =
  let name = conf_name in
  let filename = Printf.sprintf "%s/main.ml" conf_dir in
  let fs = FS.create kvs in
  let ip = IP.create kvs in
  let http = HTTP.create kvs in
  let main = Main.create kvs in
  let depends = OBuild.create kvs in
  { name; filename; fs; ip; http; main; depends }

let output_main t =
  if Sys.file_exists t.filename then
    command "mv %s %s.save" t.filename t.filename;
  let oc = open_out t.filename in
  Headers.output oc;
  FS.output oc t.fs;
  IP.output oc t.ip;
  HTTP.output oc t.http;
  Main.output oc t.main;
  OBuild.output oc t.depends;
  close_out oc

let call_crunch_scripts t =
  FS.call t.fs

let call_build_scripts t =
  let pwd = Sys.getcwd () in
  if pwd <> conf_dir then
    Sys.chdir conf_dir;
  command "obuild configure %s" (if xen then "--executable-as-obj" else "");
  command "obuild build";
  if pwd <> conf_dir then
    Sys.chdir pwd;
  let exec = Printf.sprintf "mir-%s" t.name in
  command "rm -f %s" exec;
  command "ln -s %s/dist/build/%s/%s %s" conf_dir t.name t.name exec

let call_xen_scripts t =
  let obj = Printf.sprintf "dist/build/%s/%s.native.obj" t.name t.name in
  let target = Printf.sprintf "dist/build/%s/%s.xen" t.name t.name in
  if Sys.file_exists obj then
    command "mir-build -b xen-native -o %s %s" target obj

let () =

  let lines = lines_of_file conf_file in
  let kvs = filter_map key_value lines in
  let conf = create kvs in

  (* main.ml *)
  info "Generating %s." conf.filename;
  output_main conf;

  (* crunch *)
  call_crunch_scripts conf;

  (* build *)
  call_build_scripts conf;

  (* gen_xen.sh *)
  if xen then (
    call_xen_scripts conf;
  )
