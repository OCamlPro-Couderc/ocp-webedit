open CommonConfig
open ServerConfig

(* debug *)
(*let inlog = open_out (Filename.concat (data_directory^"/offline_at_mode") "log.txt")*)

let _ =
  Unix.chdir root_directory;
  if not (Sys.file_exists "server.conf") then
    output_server_conf "server.conf"
      [
        "/login","login_service";
        "/logout", "logout_service";
        "/project", "project_service";
        "/project/load", "project_load_service";
        "/create", "create_service";
        "/createdir", "createdir_service";
        "/project/create", "project_create_service";
        "/project/save", "project_save_service";
        "/project/rename", "project_rename_service";
        "/project/import", "project_import_service";
        "/rename", "rename_service";
        "/project/delete", "project_delete_service";
        "/delete", "delete_service";
        "/import", "import_service";
        "/export", "export_service";
        "/conf/save", "save_conf_service";
        "/conf/load", "load_conf_service";
        "/project/compile", "project_compile_service";
        "/library", "load_library_service";
        "/library/install", "install_library_service";
      ]

module H = Hashtbl
(* let logged_users = H.create 127 *)

let log_error = (Sys.getcwd ())^"/log_error.txt"

let log msg =
  let out = open_out_gen [Open_wronly;Open_append;Open_creat] 0o777 log_error in
  output_string out msg;
  close_out out

(* Type to describe the directories tree af a user *)
type s_dirtree =
  S_Directory of string * s_dirtree list (* dirname, directories *)
| S_Project of string * string list * string
(* project's name, files's name, compile settings *)

type compile_result = {
  cr_path: string;
  cr_stdout : string ;
  cr_exec : string ;
  cr_bytecode : string;
  cr_code: int }

(* [my_encode s] encodes every char from s into its decimal representation (3
digits) *)
let my_encode str =
  let buf = Buffer.create 503 in
  String.iter (fun c ->
    let i = Char.code c in
    let add =
      if i < 10 then Format.sprintf "00%d" i
      else if i < 100 then Format.sprintf "0%d" i
      else (string_of_int i) in
    Buffer.add_string buf add) str;
  Buffer.contents buf

let my_decode str =
  assert ((String.length str mod 3) = 0);
  let max = String.length str / 3 in
  let buf = Buffer.create 503 in
  for i=0 to max-1 do
    let number = int_of_string (String.sub str (i*3) 3) in
    Buffer.add_char buf (Char.chr number)
  done;
  Buffer.contents buf


exception Empty_cgi_argument of Netcgi.cgi_activation * string(* cgi, argument *)
exception Bad_cgi_argument of Netcgi.cgi_activation * string (* cgi, argument *)
exception Wrong_assertion_key of string  (* user *)
exception User_not_found of string  (* user *)
exception Request_failed of string  (* Fail's reason *)
exception Cookie_not_found of string (* Cookie's name *)
exception Invalid_filename of string (* filename*)
exception Invalid_path of Netcgi.cgi_activation * string (* cgi, path *)
exception Invalid_dirname of string (* dirname *)
exception Invalid_extension of string (* filename *)
exception Bad_object_name of string

(* [string_of_cgi c] returns a string describing the arguments from the cgi [c]
*)
let string_of_cgi cgi =
  let args = List.map (fun a -> Format.sprintf "%s=%s"
    (String.escaped a#name) (String.escaped a#value)) cgi#arguments in
  Format.sprintf "cgi: args=[%s]" (String.concat "; " args)

let string_of_shellcmd cmd =
  Format.sprintf "cmd: name=%s; args=%s; chdir=%s"
    (Shell_sys.get_cmdname cmd)
    (String.concat "," (Array.to_list (Shell_sys.get_arguments cmd)))
    (match Shell_sys.get_chdir cmd with None -> "" | Some s -> s)

(** [print_exception exn cgi] is used to print the exceptions from the service
to a log file. [exn] is the exception catched, [cgi] the service that called it
*)
let print_exception exn cgi =
  let format_name_exn = " :" in
  let format_ret_exn = "\n\t" in
  let exn_msg =
    let name, params = match exn with
      | Empty_cgi_argument (c,a) ->
        "Empty_cgi_argument", [string_of_cgi c; "arg: "^a]
      | Bad_cgi_argument (c,a) ->
        "Bad_cgi_argument", [string_of_cgi c; "arg: "^a]
      | Wrong_assertion_key u -> "Wrong_assertion_key", ["user: "^u]
      | User_not_found u -> "User_not_found", ["user: "^u]
      | Request_failed r -> "Request_failed", ["reason: "^r]
      | Cookie_not_found c -> "Cookie_not_found", ["cookie: "^c]
      | Invalid_filename f -> "Invalid_filename", ["filename: "^f]
      | Sys_error s -> "Sys_error", [ s ]
      | Bad_object_name o -> "Bad_object_name", ["object_file_name: "^o]
      | _ -> "Unknown_exception", []
    in
    Format.sprintf "%s%s%s" name format_name_exn
      (match params with [] -> "" | l -> Format.sprintf "%s%s"
        format_ret_exn (String.concat format_ret_exn l))
  in
  let date_msg =
    let open Unix in
    let tm = localtime (time ()) in
    let format60 i = if i < 10 then "0"^(string_of_int i)
      else string_of_int i in
    let day = match tm.tm_wday with
        0 -> "Sun" | 1 -> "Mon" | 2 -> "Tue" | 3 -> "Wed" | 4 -> "Thu"
      | 5 -> "Fri" | 6 -> "Sat" | _-> "" in
    Format.sprintf "%s %d/%d/%d %d:%s:%s"
      day tm.tm_mday (tm.tm_mon+1) (tm.tm_year+1900) tm.tm_hour
      (format60 tm.tm_min) (format60 tm.tm_sec)
  in
  let msg = Format.sprintf "\n[Error] %s (%s) : %s" date_msg
    cgi#environment#cgi_script_name exn_msg in
  log msg



(** [list_directories path dir] return the list of directories in [path] as as
s_dirtree, with [dirname] as name *)
let rec list_directories path dirname =
  (*output_string inlog (path^"\n");*)
  let files = Array.to_list (Sys.readdir path) in
  let buildfile = Filename.concat path ".webuild" in
  if Sys.file_exists buildfile then
    let files =
      let source_list = List.filter (fun f ->
        let verify = Filename.check_suffix f in
          (verify ".ml") || (verify ".mli") || (verify ".mll") || (verify ".mly"))
          (Array.to_list (Sys.readdir path)) in
      let conf_file = Filename.concat path "dependency" in
        if not (Sys.file_exists conf_file) then source_list
        else begin
          let buf = Buffer.create 128 in
          let inc = open_in conf_file in
            Buffer.add_channel buf inc (in_channel_length inc); close_in inc;
            let lib_list = Str.split (Str.regexp "\n") (Buffer.contents buf) in
              Buffer.clear buf;
              source_list @ lib_list
          end
    in
    (*log ("\n" ^ (String.concat " " files));*)
    let buf = Buffer.create 128 in
    let inc = open_in buildfile in
    Buffer.add_channel buf inc (in_channel_length inc);
    close_in inc;
    let opts = Buffer.contents buf in
    S_Project (dirname, files, opts)
  else
    let dirs = List.filter (fun f ->
      (*output_string inlog (f^"\n");*)
      Sys.is_directory (Filename.concat path f)) files in
    let dir_list = List.map (fun dir ->
      list_directories (Filename.concat path dir) dir) dirs in
    S_Directory (dirname, dir_list)


(** [email_to_dirname e] returns the directory corresponding to the user's email
[e] *)
let email_to_dirname str =
  let pos_at = String.index str '@' in
  let add_pre_at = String.sub str 0 pos_at in
  let add_post_at = String.sub str (pos_at+1)
    (String.length str - pos_at - 1) in
  add_pre_at^"_at_"^add_post_at

(* Those are only used to create a default project when the user logs for the
first time *)
let default_dirname = "hello_project"
let default_filename = "hello_world.ml"
let default_source_content = "let _ = \n  print_endline \"Hello world !\""
let buildfile_basename = ".webuild"
let default_buildfile_content =
  "files=hello_world.ml\noutput=hello_world.byte\ndepend="

let default_ocpbuildfile_name = "build.ocp"

(** [create_default_buildfile abspath] :
    Create a default build file in the directory [abspath] **)
let create_default_buildfile abspath =
  let out = open_out (Filename.concat abspath buildfile_basename) in
  output_string out default_buildfile_content;
  close_out out

let create_default_ocpbuildfile path ?name () =
  let objective, file = match name with
    | None -> "hello_world", "\"hello_world.ml\""
    | Some name -> name, "" in
  let out = open_out (Filename.concat path default_ocpbuildfile_name) in
  let content =
    Format.sprintf "begin program \"%s\"\n\tfiles = [%s]\n\trequires = []\nend"
    objective file in
    output_string out content;
    close_out out

let parse_output_function content =
  let from = String.index content '\n' in
  let pos_start = String.index_from content from '=' in
  let pos_end = String.index_from content from '.' in
    String.sub content (pos_start+1) (pos_end-pos_start-1)

(** [parse_conf_function content]:
    parse the content between the '=' and '\n' of the first line of
    content, which is supposed to be the source files of the project
    keep the order of the files as they appeare in content**)
let parse_files_function content =
  let stract_by_key str key =
    let pos_start = (Str.search_forward (Str.regexp (key^"=")) str 0) + (String.length (key^"=")) in
    let pos_end = try String.index_from str pos_start '\n' with Not_found -> (String.length str)in
      String.sub str pos_start (pos_end - pos_start) in
  let sources = stract_by_key content "files" in
  let lib_files = stract_by_key content "depend" in
  let rec aux acc str =
    let pos =
      try String.index str ','
      with Not_found -> -1 in
    if pos <> -1 then
      let item = "\"" ^ (String.sub str 0 pos) ^ "\"" in
      let rest = String.sub str (pos + 1) ((String.length str) - pos - 1) in
        aux (item :: acc) rest
    else ("\""^str^"\"") :: acc in
  let lib_file_list = List.rev (aux [] lib_files) in
  let libraries = List.map (fun lib_file -> try (Filename.chop_extension lib_file)^"\""
                                            with _ -> lib_file ) lib_file_list in
    List.rev (aux [] sources), libraries

(** [update_ocpfiles_function path content]:
    update the ocp-build configuration file accroding to the conf file
    received by save_conf_function and passed by argument content **)
let update_ocpfiles_function path =
  let inc = open_in (Filename.concat path buildfile_basename) in
  let buf = Buffer.create 503 in
    Buffer.add_channel buf inc (in_channel_length inc);
    close_in inc;
  let content = Buffer.contents buf in
  let files = Sys.readdir path in
  let ocpfile =
    List.find (fun file -> Filename.check_suffix file ".ocp") (Array.to_list files) in
  let output_name = parse_output_function content in
  let sources, libraries = parse_files_function content in
  let concat str_lt = if str_lt = ["\"\""] then "" else String.concat " " str_lt in
  let inc = open_in (Filename.concat path ocpfile) in
  let buf = Buffer.create 503 in
    Buffer.add_string buf ("begin program \""^output_name^"\"");
    let update = "\n\tfiles = [" ^ (concat sources) ^ "]\n\trequires = ["^ (concat libraries) ^"]\nend" in
      Buffer.add_string buf update;
      close_in inc;
      let out = open_out (Filename.concat path ocpfile) in
        output_string out (Buffer.contents buf);
        close_out out

(** [create_workspace user] :
    Create a workspace for the [user], which is the login (here an email
    address). This workspace is located at root of the "data" directory.
    A default project is also created **)
let create_workspace user =
  let user_dirname = email_to_dirname user in
  let rootpath = Filename.concat data_directory user_dirname in
  let dirpath = Filename.concat rootpath "WorkSpace" in
  let projectpath = Filename.concat dirpath default_dirname in
  let filepath = Filename.concat projectpath default_filename in
  Unix.mkdir rootpath 0o777;
  let oc = open_out (Filename.concat rootpath "edit.settings") in
  output_string oc "theme=eclipse";
  close_out oc;
  Unix.mkdir dirpath 0o777;
  Unix.mkdir projectpath 0o777;
  let oc = open_out filepath in
  output_string oc default_source_content;
  close_out oc;
  create_default_buildfile projectpath;
  create_default_ocpbuildfile projectpath ()

let create_buildfile path output files =
  let out = open_out (Filename.concat path buildfile_basename) in
  let sources = List.filter (fun file ->
    (Filename.check_suffix file ".ml") || (Filename.check_suffix file ".mli")) files in
  let sources = Format.sprintf "files=%s" (String.concat "," sources) in
  let output = Format.sprintf "output=%s" output in
  output_string out (sources ^"\n" ^ output ^ "\ndepend=");
  close_out out


let create_temp_archive path tar_content =
  let f = open_out path in
  for i = 0 to (String.length tar_content) - 1 do
    output_byte f (Char.code (tar_content.[i]))
  done;
  close_out f

(** [user_exists user] :
    Return true if [user], which is the login, exists in our system,
    ie. a workspace for this user exists **)
let user_exists user =
  let user_dirname = email_to_dirname user in
  let path = Filename.concat data_directory user_dirname in
  Sys.file_exists path && Sys.is_directory path


(** NOT IMPLEMENTED YET **)
let verify_logged_user _user _key = ()
  (* if not (H.mem logged_users user) then *)
  (*   () (\* /!\ temporary *\) *)
  (* else *)
  (*   let stored_key = H.find logged_users user in *)
  (*   if stored_key <> key then *)
  (*     raise Wrong_assertion_key *)


(** [verify_go_up str] :
    Return true if [str] contains ".." **)
let verify_go_up str =
  let b = ref false in
  String.iteri (fun i c ->
    if c = '.' && i < String.length str - 1 then
      if str.[i+1] = '.' then b := true) str;
  !b

(** [verify_cookie cgi name] :
    Return the value of argument [name] located in a cookie of [cgi] **)
let verify_cookie (cgi: Netcgi.cgi_activation) name =
  let cgi = cgi#environment in
  let c = cgi#cookies in
  try
    let res = List.find (fun co -> (Netcgi.Cookie.name co) = name) c in
    Netcgi.Cookie.value res
  with Not_found -> raise (Cookie_not_found(name))

(** [verify_argument cgi name] :
    Return the value of [name] argument of the [cgi] with some
    verifications.
    Raise [Empty_cgi_argument] if [name]'s value in [cgi] is empty and th
    [empty] argument is false;
    Raise [Bad_cgi_argument] if [name] doesn't exist in [cgi] **)
let verify_argument ?(empty=false) (cgi: Netcgi.cgi_activation) name =
  if cgi#argument_exists name then begin
    let value = cgi#argument_value name in
    if value <> "" || empty then value
    else raise (Empty_cgi_argument(cgi, name)) end
  else raise (Bad_cgi_argument(cgi, name))


(** [verify_user cgi] :
    Verify the user's identity and return the dirname of his workspace
    Warning: Disabled on offline_mode **)
(*let verify_user cgi =
  if not offline_mode then
    let user = verify_cookie cgi "user" in
    let key = verify_cookie cgi "key" in
    verify_logged_user user key;
    email_to_dirname user
  else email_to_dirname "offline@mode"*)
let verify_user cgi =
  let user = verify_cookie cgi "user" in
  let key = verify_cookie cgi "key" in
    verify_logged_user user key;
    email_to_dirname user

(** [verify_path cgi] :
    Return the absolute path where the [cgi] must act in the "data"
    directory **)
let verify_path cgi =
  let path = verify_argument cgi "path" in
  if (not (Filename.is_implicit path)) || (verify_go_up path) then
    raise (Invalid_path (cgi, path));
  Filename.concat data_directory path

(** [verify_dirname name] :
    Raise [Invalid_dirname] if [name] doesn't match with our dirname rules **)
let verify_dirname name =
  let dir_sep = Filename.dir_sep.[0] in (* a way more pretty ? *)
  if (String.contains name dir_sep) || (verify_go_up name) then
    raise (Invalid_dirname name)


(** [verify_filename name] :
    Raise [Invalid_filename] if [name] doesn't match with our filename rules **)
let verify_filename name =
  let dir_sep = Filename.dir_sep.[0] in (* a way more pretty ? *)
  let check_ext = Filename.check_suffix name in
  if not (check_ext ".ml" || check_ext ".mli" || check_ext ".cma" ||
          check_ext ".mll" || check_ext ".mly" ||
          check_ext ".cmi" ||  check_ext ".prims" ) ||
    Filename.chop_extension name = "" ||
    String.contains name dir_sep ||
    verify_go_up name then
    raise (Invalid_filename name)

(** [verify_conffilename name] :
    Raise [Invalid_filename] if [name] doesn't match with our conf file's
    name rules **)
let verify_conffilename name =
  let dir_sep = Filename.dir_sep.[0] in (* a way more pretty ? *)
  if (String.contains name dir_sep) || (verify_go_up name) then
    raise (Invalid_filename name)

(** [answer cgi str] :
    Answer to the given [cgi] with a string [str] **)
let answer (cgi: Netcgi.cgi_activation) str =
  cgi#out_channel#output_string str;
  cgi#out_channel#commit_work ()

let send_file absolute_path file (cgi: Netcgi.cgi_activation) =
  cgi#set_header ~content_type:"application/octet-stream" ~filename:file ();
  let f = open_in_bin absolute_path in
  let ic = new Netchannels.input_channel f in
  cgi#out_channel#output_channel ic;
  cgi#out_channel#commit_work ()

let send_cookies cookies (cgi: Netcgi.cgi_activation) =
  cgi#set_header ~set_cookies:cookies ~cache:`No_cache ();
  cgi#out_channel#output_string "Authentified successfully";
  cgi#out_channel#commit_work ()

(* Dead code, to remove later *)
let parse_persona_response r =
  let open Yojson.Basic in
  let res = from_string r in
  let status = Util.member "status" res in
  if (Util.to_string status) = "okay" then
    Util.to_string (Util.member "email" res)
  else
    let reason = Util.member "reason" res in
    raise (Request_failed (to_string reason))


(** [login_function assertion] :
    Return user's login after verifying the assertion key on Persona server **)
(*let login_function email password =
  let user =
    if not offline_mode then begin
      let open Http_client.Convenience in
      let data = [("assertion", assertion); ("audience", server_name)] in
      let req = http_post_message "https://verifier.login.persona.org/verify"
        data in
      while not (req#is_served) do () done; (* Critical point *)
      let body = req#response_body in
      parse_persona_response body#value end
    else "offline@mode" in
  (* H.replace logged_users user assertion; *)
  if not (user_exists user) then create_workspace user;
  user*)
let login_function email password =
  (* let identified = ref true in *)
  let identified =
    try Admintool.user_identify email password ; true
    with Admintool.SELECT_USER_FAIL (email, psw_sha) -> begin
      (* identified := false; *)
      log ("select fail detected: " ^ email ^ " " ^ psw_sha);
      false
    end in
  if identified && not (user_exists email) then create_workspace email;
  identified

(* let signup_function email password name =
  AdminLib.create_user email password name;
  if not (user_exists email) then create_workspace email *)


(** [project_function user] :
    Return the string representation of all files/directories of the
    [user]'s workspace **)
let project_function user =
  let path = Filename.concat data_directory user in
  let res = list_directories path user in
  (*close_out inlog;*)
  let s = Marshal.to_string res [] in
  my_encode s

(* TODO: we use [my_encode] and [my_decode] to pass binary data over the
xmlHttpRequest. It is not optimal, but it works for now. *)

(** [project_load_function path file] :
    Return the content of [file] located in [path] directory **)
let project_load_function path file =
  verify_filename file;
  let inc = open_in_bin (Filename.concat path file) in
  let len = in_channel_length inc in
  let buf = Buffer.create len in
  Buffer.add_channel buf inc len;
  close_in inc;
  let s = Buffer.contents buf in
(*  log (Printf.sprintf "project_load_function %S -> %d/%d\n" file len (String.length s)); *)
  my_encode s

(** [createdir_function path name] :
    Create a new directory called [name] in [path] **)
let createdir_function path name =
  verify_dirname name;
  let path = Filename.concat path name in
  Unix.mkdir path 0o777

(** [create_function path name] :
    Create a new project called [name] in [path] **)
let create_function path name =
  createdir_function path name;
  let project_path = Filename.concat path name in
  let conf_file = open_out (Filename.concat project_path ".webuild") in
    output_string conf_file "files=\noutput=\ndepend=";
    close_out conf_file;
    create_default_ocpbuildfile project_path ~name ()

(** [project_create_function path file] :
    Create a project [file] in [path] **)
let project_create_function path file =
  verify_filename file;
  let out = open_out (Filename.concat path file) in
  output_string out (CommonMisc.initial_file_content file);
  close_out out

(** [project_save_function path file content] :
    Save [content] in project [file] located in [path] **)
let project_save_function path file content =
  verify_filename file;
  let out = open_out (Filename.concat path file) in
  output_string out content;
  close_out out

(** [rename_function path name new_name] :
    Rename the directory [name] located in [path] in [new_name] **)
let rename_function path name new_name =
  verify_dirname name;
  verify_dirname new_name;
  Sys.rename (Filename.concat path name) (Filename.concat path new_name)

(** [project_rename_function path name new_name] :
    Rename the project file named [name] in [new_name] **)
let project_rename_function path name new_name =
  verify_filename name;
  verify_filename new_name;
  Sys.rename (Filename.concat path name) (Filename.concat path new_name)

(** [delete_function path name] :
    Delete the directory [name] located in [path] **)
let rec delete_function ?(verify=true) path name =
  if verify then verify_dirname name;
  let path = Filename.concat path name in
  Array.iter
    (fun f ->
      let abspath = Filename.concat path f in
      if Sys.is_directory abspath then delete_function path f
      else Sys.remove abspath)
    (Sys.readdir path);
  Unix.rmdir path


(** [clean_directory p] removes every directory in [p] and each file without
    .ml or .mli extension *)
let clean_directory path =
  let files = Sys.readdir path in
  Array.iter (fun f ->
    let fpath = Filename.concat path f in
    if Sys.is_directory fpath then
      delete_function ~verify:false path f
    else if not (Filename.check_suffix f ".ml"
              || Filename.check_suffix f ".mli"
              || Filename.check_suffix f ".cma"
              || Filename.check_suffix f ".ocp"
              || f = ".webuild") then
      Sys.remove fpath)
    files


(** [project_delete_function path file] :
    Delete the project [file] located in [path] **)
let project_delete_function path file =
  verify_filename file;
  if not (Filename.check_suffix file ".cma") then Sys.remove (Filename.concat path file)
  else
    let conf_file = Filename.concat path "dependency" in
    let buf = Buffer.create 64 in
    let inc = open_in conf_file in
      Buffer.add_channel buf inc (in_channel_length inc); close_in inc;
      let lib_list = Str.split (Str.regexp "\n") (Buffer.contents buf) in
      let new_list = List.find_all (fun f -> not (f = file)) lib_list in
        if new_list = [] then Sys.remove conf_file
        else
          let out = open_out conf_file in
            output_string out (String.concat "\n" new_list); close_out out


(** [import_function path file content] imports the archive [file] whose binary
    content is in [content], and extract it in [p] as a new project. File order
    is arbitrary. *)
let import_function path file tar_content =
  let tar_content = my_decode tar_content in
  if Filename.check_suffix file ".tar.gz" then
    begin
      let dir = Filename.chop_extension (Filename.chop_extension file) in
      verify_dirname dir;
      let file = "temp_archive.tar.gz" in
      let fpath = Filename.concat path file in
      let path = Filename.concat path dir in
      create_temp_archive fpath tar_content;
      Unix.mkdir path 0o777;
      let cmd = Format.sprintf "tar -zxf \"%s\" -C \"%s\"" fpath path in
      ignore (Sys.command cmd);
      Sys.remove fpath;
      clean_directory path;
      let conf = Sys.file_exists (Filename.concat path ".webuild") in
      if not conf then create_default_buildfile path;
      let p = list_directories path dir in
      if not conf then begin
        let files = match p with
          | S_Project (_, f, _) -> f
          | S_Directory _ -> assert false
        in
        create_buildfile path (dir ^ ".byte") files;
      end;
      create_default_ocpbuildfile path ~name:dir ();
      update_ocpfiles_function path;
      let res = list_directories path dir in
      let res = Marshal.to_string res [] in
      my_encode res
    end
  else
    raise (Invalid_extension file)


(** [export_function path dir] :
    Create an archive of the [dir] located in [path] and return
    the archive's absolute and relative name **)
let export_function path dir =
  verify_dirname dir;
  let archive = Format.sprintf "%s.tar.gz" dir in
  let abs_archive = Filename.concat path archive in
  let files = Sys.readdir path in
  let files = Array.fold_left
    (fun acc f ->
      if Filename.check_suffix f ".ml" || Filename.check_suffix f ".mli" || Filename.check_suffix f ".cma"
        || f = ".webuild" || f = "ocp-build.ocp"
      then f::acc else acc)
    []
    files in
  let files = String.concat " " files in
  Format.printf "%s@." files;
  let cmd = Format.sprintf "tar -zcf \"%s\" -C \"%s\" %s" abs_archive path files in
  ignore (Sys.command cmd);
  abs_archive, archive

(** [save_conf_function path name content] :
    Save the [content] into conf file [name] located in [path] **)
let save_conf_function path name content =
  verify_conffilename name;
  let out = open_out (Filename.concat path name) in
  output_string out content;
  close_out out

(** [load_conf_function path name] :
    Return the content of conf file [name] located in [path] **)
let load_conf_function path name =
  verify_conffilename name;
  let inc = open_in (Filename.concat path name) in
  let buf = Buffer.create 503 in
  Buffer.add_channel buf inc (in_channel_length inc);
  close_in inc;
  Buffer.contents buf

let ocp_build path subcom =
  let subcom_list = Str.split (Str.regexp " ") subcom in
  let err = Unix.openfile (Filename.concat path "errfile") [Unix.O_WRONLY; Unix.O_CREAT] 0o777 in
  let child_pid = Unix.create_process "ocp-build" (Array.of_list ("ocp-build"::subcom_list))
                  Unix.stdin Unix.stdout err in
  let return_pid, return_code = Unix.waitpid [] child_pid in
    assert (return_pid = child_pid);
    Unix.close err;
    match return_code with
      | Unix.WEXITED c -> c
      | Unix.WSTOPPED _ | Unix.WSIGNALED _ -> -1

let read_to_string path =
  let inc = open_in path in
  let len = in_channel_length inc in
  let buf = Buffer.create len in
    Buffer.add_channel buf inc len;
    close_in inc;
    Buffer.contents buf, len

let infer_grun user_agent =
  let (/) lhs rhs = Filename.concat lhs rhs in
    www_directory / "ocamlgrun" / (
      match user_agent with
        | s when Str.string_match (Str.regexp ".*Mac") s 0 -> "ocamlgrun-macosx10.9-x86_64.bin"
        | s when Str.string_match (Str.regexp ".*\\(Linux\\|X11\\)") s 0 -> "ocamlgrun-linux-debian-x86.bin"
        | s when Str.string_match (Str.regexp ".*Windows NT 6.1") s 0 -> "ocamlgrun-win7-amd64.exe"
        | _ -> "" )

let project_compile_function path obj user_agent =
  let (/) lhs rhs = Filename.concat lhs rhs in
  let original_path = Sys.getcwd () in
  let env_path = Unix.getenv "PATH" in
    Unix.chdir path;

    let path_to_prefix = root_directory / "opam/4.00.1/bin:" in
      if not (Str.string_match (Str.regexp path_to_prefix) env_path 0) then
        Unix.putenv "PATH" (path_to_prefix ^ env_path);

      let code = ref 0 in
      let output = path / "errfile" in
      let _ =
        if Sys.file_exists output then Sys.remove output;
        code := ocp_build path (if Sys.file_exists (path / "ocp-build.root") then "build" else "-init") in

      let output_ocpbuild, len = read_to_string output in
      let start = try Str.search_backward (Str.regexp "\n\n") output_ocpbuild (len - 3)
                  with Not_found -> -1 in
      let stdout = if start <> -1 then String.sub output_ocpbuild (start + 2) (len - start - 4)
                   else "Building Successfully" in

      let grun_path = infer_grun user_agent in
      let grun = open_in_bin grun_path in
      let grun_len =
        if (* (Filename.basename grun_path) = "ocamlgrun" *)true then 0 else in_channel_length grun in

      let bytecode_path = path / "_obuild" / (Filename.chop_extension obj) / obj in
      let bytecode = open_in_bin bytecode_path in
      let bytecode_len = in_channel_length bytecode in

      let buf = Buffer.create (grun_len + bytecode_len) in
        Buffer.add_channel buf grun grun_len;
        Buffer.add_channel buf bytecode bytecode_len;
        close_in grun; close_in bytecode;

        Unix.chdir original_path;
        Unix.putenv "PATH" env_path;
        let result = {  cr_path = (Str.global_replace (Str.regexp (data_directory^Filename.dir_sep)) "" path);
                        cr_stdout = stdout;
                        cr_exec = (Filename.chop_extension obj);
                        cr_bytecode = (Buffer.contents buf);
                        cr_code = !code } in
        let res = Marshal.to_string result [] in
          my_encode res

let load_library_function () =
  let in_file = Filename.concat root_directory "webedit.conf" in
  (* let _ = if not (Sys.file_exists in_file) then (* AdminLib.build_server_config () *) in *)
  let inc = open_in in_file in
  let len = in_channel_length inc in
  let buf = Buffer.create 128 in
    Buffer.add_channel buf inc len;
    let lib_list = Str.split (Str.regexp "\n") (Buffer.contents buf) in
    let res = Marshal.to_string lib_list [] in
      my_encode res

let install_library_function path lib =
  let conf_file = Filename.concat path "dependency" in
  let buf = Buffer.create 64 in
  let lib_list =
    if Sys.file_exists conf_file then
      let inc = open_in conf_file in
        Buffer.add_channel buf inc (in_channel_length inc); close_in inc;
        Str.split (Str.regexp "\n") (Buffer.contents buf)
    else [] in
    let new_list = if (List.mem lib lib_list) then lib_list else lib :: lib_list in
    let out = open_out conf_file in
      output_string out (String.concat "\n" new_list); close_out out


let empty_dyn_service =
  { Nethttpd_services.dyn_handler = (fun _ _ -> ());
    dyn_activation = Nethttpd_services.std_activation
      `Std_activation_buffered;
    dyn_uri = None;
    dyn_translator = (fun _ -> "");
    dyn_accept_all_conditionals=false; }


let login_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          let uid = verify_argument cgi "email" in
          let psw = verify_argument cgi "psw" in
          if (login_function uid psw) then
            let u = Nethttp.Cookie.make "user" uid in
            let p = Nethttp.Cookie.make "key" psw in
            send_cookies [u; p] cgi
          else
            raise (Request_failed "Login error")
	with e -> print_exception e cgi
      ); }

(* let signup_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
  try
          let email = verify_argument cgi "email" in
          let psw = verify_argument cgi "psw" in
          let name = verify_argument cgi "name" in
          let success = ref true in
          let _ =
            try signup_function email psw name
            with
              | AdminLib.Email_WrongFormat _ ->
                  answer cgi "wformat"; success := false
              | AdminLib.Email_AlreadyExist _ ->
                  answer cgi "exist"; success := false in
            if !success then
              let u = Nethttp.Cookie.make "user" email in
              let k = Nethttp.Cookie.make "key" psw in
                send_cookies [u; k] cgi
  with e -> print_exception e cgi
      ); }
 *)
let logout_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          (* H.remove logged_users user; *)
          answer cgi"Logged_out"
	with e -> print_exception e cgi
      ); }


let project_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          let user = verify_user cgi in
	  let res = project_function user in
	  answer cgi res
	with e -> print_exception e cgi
      ); }


let project_load_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
          cgi#set_header ~content_type:"application/octet-stream" ~filename:file ();
	  let res =
      if Filename.check_suffix file ".cma" then my_encode "This file is a binary file. It's unreadable."
      else project_load_function path file in
	  answer cgi res
	with e -> print_exception e cgi
      ); }

let create_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let project = verify_argument cgi "name" in
	  create_function path project;
	  answer cgi "Project created successfully"
	with e -> print_exception e cgi
      ); }

let createdir_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let project = verify_argument cgi "name" in
	  createdir_function path project;
	  answer cgi "Directory created successfully"
	with e -> print_exception e cgi
      ); }

let project_create_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
	  project_create_function path file;
	  answer cgi "File created successfully"
	with e -> print_exception e cgi
      ); }

let project_save_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
	  let content = verify_argument cgi "content" ~empty:true in
	  project_save_function path file content;
	  answer cgi "Saved"
	with e -> print_exception e cgi
      ); }

let project_import_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
	  let content = verify_argument cgi "content" in
	  project_save_function path file content;
	  answer cgi "Imported"
	with e -> print_exception e cgi
      ); }

let rename_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let project = verify_argument cgi "name" in
	  let new_name = verify_argument cgi "newname" in
	  rename_function path project new_name;
	  answer cgi "Renamed"
	with e -> print_exception e cgi
      ); }

let project_rename_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
	  let new_name = verify_argument cgi "newname" in
	  project_rename_function path file new_name;
	  answer cgi "Renamed"
	with e -> print_exception e cgi
      ); }

let delete_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let project = verify_argument cgi "name" in
	  delete_function path project;
	  answer cgi "Deleted"
	with e -> print_exception e cgi
      ); }

let project_delete_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let file = verify_argument cgi "name" in
	  project_delete_function path file;
	  answer cgi "Deleted"
	with e -> print_exception e cgi
      ); }

let import_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          (* ignore (verify_user cgi); *)
          let path = verify_path cgi in
          let file = verify_argument cgi "file" in
          let content = verify_argument cgi "content" in
          let s_project = import_function path file content in
          answer cgi s_project
	with e -> print_exception e cgi
      ); }

let export_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
	  let project = verify_argument cgi "name" in
	  let abs_f, f = export_function path project in
	  send_file abs_f f cgi
	with e -> print_exception e cgi
      ); }

let save_conf_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
          let name = verify_argument cgi "name" in
	  let content = verify_argument cgi "content" in
	  save_conf_function path name content;
    if name = ".webuild" then update_ocpfiles_function path;
	  answer cgi "Saved"
	with e -> print_exception e cgi
      ); }

let load_conf_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
	try
          ignore (verify_user cgi);
          let path = verify_path cgi in
          let name = verify_argument cgi "name" in
	  let res = load_conf_function path name in
	  answer cgi res
	with e -> print_exception e cgi
      ); }

let project_compile_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
  try
          ignore (verify_user cgi);
          let path = verify_path cgi in
          let obj = verify_argument cgi "obj" in
          let user_agent = cgi#environment#user_agent in
      let res = project_compile_function path obj user_agent in
      answer cgi res
  with e -> print_exception e cgi
      ); }

let load_library_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
  try
          let _ = ignore (verify_user cgi) in
    let res = load_library_function () in
    answer cgi res
  with e -> print_exception e cgi
      ); }

let install_library_service =
  { empty_dyn_service with
    Nethttpd_services.dyn_handler =
      (fun _ cgi ->
        try
          let path = verify_path cgi in
          let lib = verify_argument cgi "lib" in
            install_library_function path lib;
            answer cgi "Installed"
        with e -> print_exception e cgi
      ); }

let my_factory =
  Nethttpd_plex.nethttpd_factory
    ~name:"ace-edit_processor"
    ~handlers: [
      "login_service", login_service;
      "logout_service", logout_service;
      "project_service", project_service ;
      "project_load_service", project_load_service;
      "project_create_service", project_create_service;
      "create_service", create_service;
      "createdir_service", createdir_service;
      "project_save_service", project_save_service;
      "project_import_service", project_import_service;
      "rename_service", rename_service;
      "project_rename_service", project_rename_service;
      "delete_service", delete_service;
      "project_delete_service", project_delete_service;
      "import_service", import_service;
      "export_service", export_service;
      "save_conf_service", save_conf_service;
      "load_conf_service", load_conf_service;
      "project_compile_service", project_compile_service;
      "load_library_service", load_library_service;
      "install_library_service", install_library_service;
    ] ()

let main() =
  (* Create a parser for the standard Netplex command-line arguments: *)
  let (opt_list, cmdline_cfg) = Netplex_main.args() in

  (* Parse the command-line arguments: *)
  Arg.parse
    opt_list
    (fun s -> raise (Arg.Bad ("Don't know what to do with: " ^ s)))
    "usage: netplex [options]";

  (* Select multi-processing: *)
  let parallelizer = Netplex_mt.mt() in

  (* Start the Netplex system: *)
  Netplex_main.startup
    parallelizer
    Netplex_log.logger_factories
    Netplex_workload.workload_manager_factories
    [ my_factory ]
    cmdline_cfg

let _ =
  (* Enables SSL for Http_client.Convenience *)
  Ssl.init();
  Http_client.Convenience.configure_pipeline
    (fun p ->
      let ctx = Ssl.create_context Ssl.TLSv1 Ssl.Client_context in
      let tct = Https_client.https_transport_channel_type ctx in
      p # configure_transport Http_client.https_cb_id tct
    );

  Netsys_signal.init ();
  main()
