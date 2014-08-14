
open Global
open Myparser
open Myutils

type typefile = Module | Interface | Library | Lexer | Grammar

exception Bad_directory_name of directory * string (* parent dir, name *)
exception Bad_file_name of project * string (* file's project, filename *)
exception File_not_found of int (* file's id *)
exception Project_not_found of int (* project's id *)
exception Directory_not_found of int (* dir's id *)
exception Workspace_already_opened
exception Workspace_closed
exception Bad_path of string (* path *)
exception Operation_denied of string (* operation's name *)


(** Default directory separator in our filemanager **)
let dir_sep = "/"

(** Default value for project's compilation settings **)
let default_compile_opts = { cc_files = [] ; cc_output = "a.byte" }

(** Default value for edit settings **)
let default_edit_settings = { ec_theme = "eclipse" }

(** Reference for unique file id **)
let f_id = ref 0

(** Reference for unique project id **)
let p_id = ref 0

(** Reference for unique directory id **)
let dir_id = ref 0

(** Current workspace **)
let workspace = ref None

(** User's edit settings **)
let edit_settings = ref default_edit_settings

(** Current file selected in the [workspace] **)
let current_file = ref None

(** List of existing directories in the [workspace] indexed by the dir's id **)
let existing_directories = Hashtbl.create 19

(** List of existing projects in the [workspace] indexed by the project's id **)
let existing_projects = Hashtbl.create 19

(** List of existing files in the [workspace] indexed by the file's id**)
let existing_files = Hashtbl.create 19

(** Number of files opened in the [workspace] **)
let nb_files_opened = ref 0

(** History of order of current opened file of the [workspace] **)
let opened_file_order = ref []

(** Content of all opened files of the [workspace] indexed by the file's id
   If the file has never been opened, there are no entry of it
   If the file has been opened but is currently closed, the content is the last
     state (unsaved or saved) of the file **)
let file_content = Hashtbl.create 19

let lib_list = ref []

(** Welcome message when no files are opened **)
let welcome_session =
  "Welcome in ocp-webedit !\n\n" ^
    "Select or create a file and edit it in the editor.\n" ^
    "Once your code is ready, click on the \"Compile\" button.\n" ^
    "If compilation is successful, you can download the generated bytecode " ^
    "and run it on your system with \"ocamlrun my_program.byte\"\n" ^
    "Have fun !\n\n" ^
    "        ****\n" ^
    "      ******\n" ^
    "    ********    ****  ****\n" ^
    "        ****    **********\n" ^
    "        ****  **************\n" ^
    "        **********************\n" ^
    "        ************************\n" ^
    "          ********    ******  **\n" ^
    "            ****        ****\n" ^
    "            ****        ****\n" ^
    "            ****        ****\n" ^
    "            ****        ****\n" ^
    "            ****        ****\n\n" ^
    "(This Camel is provided by Remy El Sibaie & Jean-Christophe Filliâtre)"




(** ************************************ **)







(** [intern_exists_dir dir name] :
    Return true if [dir] has a child named [name] **)
let intern_exists_dir dir name =
  List.exists (fun dt -> match dt with
  | Project p -> p.p_name = name
  | Directory d -> d.dir_name = name
  | File _ -> assert false) dir.dir_dirs

(** [intern_find_dir dir name] :
    Return the dirtree named [name] located in [dir] **)
let intern_find_dir dir name =
  List.find (fun dt -> match dt with
  | Project p -> p.p_name = name
  | Directory d -> d.dir_name = name
  | File _ -> assert false
) dir.dir_dirs

let intern_add_file pj filename =
  let f = { f_id = !f_id ; f_project = pj.p_id ;
            f_name = filename ; f_is_open = false ;
            f_is_unsaved = false } in
  Hashtbl.add existing_files !f_id f;
  incr f_id;
  f

(** [intern_add_project id_parent name files opts] add a project [name]
    to the workspace. [parent] is the the project's parent dir, [files]
    its files, and [opts] its compilation settings **)
let intern_add_project parent name files opts =
  let p_compile_opts =
    try parse_to_compile_conf (parse_to_conf opts)
    with _ ->
      failwith ("Failed to parse conf file of project "^name) in
(*
  let p_files = (* Reorder from project's compile settings *)
    try List.rev (reorder p_files p_compile_opts)
    with Not_found -> p_files in
*)
  let p = { p_id = !p_id ; p_parent = parent.dir_id;
            p_name = name ; p_files= [] ; p_compile_opts } in
  Hashtbl.add existing_projects !p_id p;
  incr p_id;
  List.iter (fun fn -> ignore(intern_add_file p fn)) files;
(*  let reorder files opts =
    List.fold_left (fun acc f ->
      let file = List.find (fun fi -> fi.f_name = f) files in
      file :: acc) [] opts.cc_files in
  p.p_files <- reorder p.p_files p_compile_opts; *)
  parent.dir_dirs <- (Project p)::parent.dir_dirs;
  p



(** [intern_create_workspace s_dirtree] :
    Create a workspace from a [s_dirtree] given by the server and
    return the workspace built **)
let intern_create_workspace s_dirtree =
  let rec build_workspace parent = function
    | S_Directory (n,dl) ->
      let id = !dir_id in
      incr dir_id;
      let dir_dirs = List.fold_left (fun acc d ->
        (build_workspace id d)::acc) [] dl in
      let d = { dir_id = id ; dir_is_root = false ; dir_parent = parent ;
                dir_name = n ; dir_dirs } in
      Hashtbl.add existing_directories id d;
      Directory d
    | S_Project (n,fl,opts) ->
      let reorder files opts =
        List.fold_left (fun acc f ->
          let file = List.find (fun fi -> fi.f_name = f) files in
          file :: acc) [] opts.cc_files in
      let p_files = List.fold_left (fun acc fn ->
        let f = { f_id = !f_id ; f_project = !p_id ;
                  f_name = fn ; f_is_open = false ;
                  f_is_unsaved = false } in
        Hashtbl.add existing_files !f_id f;
        incr f_id;
        f::acc) [] fl in
      let p_compile_opts =
        try
          parse_to_compile_conf (parse_to_conf opts)
        with _ -> failwith ("Failed to parse conf file of project "^n) in
      let p_files = (* Reorder from project's compile settings *)
        try List.rev (reorder p_files p_compile_opts)
        with Not_found -> p_files in
      let p = { p_id = !p_id ; p_parent = parent;
                p_name = n ; p_files ; p_compile_opts } in
      Hashtbl.add existing_projects !p_id p;
      incr p_id;
      Project p
  in
  let root = function
    | S_Project _ -> assert false
    | S_Directory (n,dl) ->
      let id = !dir_id in
      incr dir_id;
      let dir_dirs = List.fold_left (fun acc d ->
        (build_workspace id d)::acc) [] dl in
      let d = { dir_id = id ; dir_is_root = true ; dir_parent = -1 ;
                dir_name = n ; dir_dirs } in
      Hashtbl.add existing_directories id d;
      d in
  let w = root s_dirtree in
  workspace := Some w;
  w


(** [intern_create_directory dir name]
    Create a new directory named [name] into [dir] and return it **)
let intern_create_directory dir name =
  let d = { dir_id = !dir_id ;
            dir_is_root = false ;
            dir_parent = dir.dir_id ;
            dir_name = name ;
            dir_dirs = [] } in
  Hashtbl.add existing_directories !dir_id d;
  incr dir_id;
  dir.dir_dirs <- (Directory d)::dir.dir_dirs;
  d

(** [intern_create_project dir name]
    Create a new project named [name] into the directory [dir] and return it **)
let intern_create_project dir name =
  let p = { p_id = !p_id ;
            p_name = name ;
            p_files = [] ;
            p_parent = dir.dir_id ;
            p_compile_opts = default_compile_opts } in
  Hashtbl.add existing_projects !p_id p;
  incr p_id;
  dir.dir_dirs <- (Project p)::dir.dir_dirs;
  p


(** [intern_create_file project name]
    Create a new file named [name] into the [project] and return it **)
let intern_create_file project name =
  let f = { f_id = !f_id ;
            f_project = project.p_id ;
            f_name = name ;
            f_is_open = false ;
            f_is_unsaved = false } in
  Hashtbl.add existing_files !f_id f;
  incr f_id;
  project.p_files <- f::project.p_files;
  f

(** [intern_set_welcome_session] :
    Set the current editSession of Ace to welcome session **)
(* Ace bug when we modify it when editor is not in DOM
  -> TODO : hide editor instead of remove/add in DOM *)
let intern_set_welcome_session () =
  (Global.editor())##selectAll();
  (Global.editor())##removeLines();
  (Global.editor())##setValue(Js.string welcome_session);
  (Global.editor())##moveCursorTo(0,0);
  (Global.editor())##getSession()##setMode(Js.string "");
  (Global.editor())##setReadOnly(Js.bool true)


(** [intern_delete_file file] :
    Delete all occurences in the workspace about the [file] **)
let intern_delete_file file =
  let id = file.f_id in
  if file.f_is_open then begin
    decr nb_files_opened;
    if !nb_files_opened = 0 then intern_set_welcome_session ();
    opened_file_order := List.filter (fun f -> f.f_id <> id)
      !opened_file_order;
    match !current_file with
    | Some f when f.f_id = id -> current_file := None
    | _ -> () end;
  Hashtbl.remove existing_files id;
  Hashtbl.remove file_content id;
  let project = Hashtbl.find existing_projects file.f_project in
  let new_files = List.fold_left (fun acc f ->
    if f.f_name = file.f_name then acc
    else f::acc) [] project.p_files in
  project.p_files <- new_files


(** [intern_delete_project project] :
    Delete all occurences in the workspace about the [project] **)
let intern_delete_project project =
  let p_files = project.p_files in
  List.iter (fun f -> intern_delete_file f) project.p_files;
  project.p_files <- p_files;
  let par = Hashtbl.find existing_directories project.p_parent in
  par.dir_dirs <- List.filter (fun dt ->
    match dt with
    | Directory _ -> true
    | Project p -> p.p_id <> project.p_id
    | File _ -> assert false) par.dir_dirs;
  Hashtbl.remove existing_projects project.p_id


(** [intern_delete_directory dir] :
    Delete all occurences in the workspace about the [dir] **)
let rec intern_delete_directory dir =
  assert (not dir.dir_is_root);
  let dir_dirs = dir.dir_dirs in
  List.iter (fun dt ->
    match dt with
    | Directory d -> intern_delete_directory d
    | Project p -> intern_delete_project p
    | File _ -> assert false) dir.dir_dirs;
  dir.dir_dirs <- dir_dirs;
  let p = Hashtbl.find existing_directories dir.dir_parent in
  p.dir_dirs <- List.filter (fun dt ->
    match dt with
    | Project _ -> true
    | Directory d -> d.dir_id <> dir.dir_id
    | File _ -> assert false) p.dir_dirs;
  Hashtbl.remove existing_directories dir.dir_id


(** [intern_update_editor_theme ()] update the editor's theme which the
    current edit settings' theme **)
let intern_update_editor_theme () =
  let theme = "ace/theme/"^(!edit_settings).ec_theme in
  (Global.editor())##setTheme(Js.string theme)



(** ************************************ **)




let get_file id =
  try Hashtbl.find existing_files id
  with Not_found -> raise (File_not_found id)

let get_project id =
  try Hashtbl.find existing_projects id
  with Not_found -> raise (Project_not_found id)

let get_directory id =
  try Hashtbl.find existing_directories id
  with Not_found -> raise (Directory_not_found id)

let get_workspace () =
  match !workspace with
  | None -> raise Workspace_closed
  | Some w -> w

let get_lib_list () =
  !lib_list

let get_current_file () =
  !current_file

let get_current_project () =
  match !current_file with
  | None -> None
  | Some f ->
    let p = get_project f.f_project in
    Some p

let get_current_directory () =
  match !current_file with
  | None -> None
  | Some f ->
    let p = get_project f.f_project in
    let d = get_directory p.p_parent in
    Some d

let get_files () =
  Hashtbl.fold (fun _ f acc -> f::acc) existing_files []

let get_projects () =
  Hashtbl.fold (fun p_id p acc ->
    if p_id = 0 then acc else p::acc) existing_projects []

let get_directories () =
  Hashtbl.fold (fun _ d acc -> d::acc) existing_directories []

let get_file_from_project project name =
  List.find (fun f -> f.f_name = name) project.p_files

let get_project_from_file file =
  get_project file.f_project

let can_create_dir dir name =
  not (intern_exists_dir dir name)

let can_create_file project name =
  not (List.exists (fun f -> f.f_name = name) project.p_files)

let rec get_path = function
  | Directory d when d.dir_is_root -> d.dir_name
  | Directory d ->
    let par = Directory (get_directory d.dir_parent) in
    (get_path par) ^ dir_sep ^ d.dir_name
  | Project p ->
    let par = Directory (get_directory p.p_parent) in
    (get_path par) ^ dir_sep ^ p.p_name
  | File f -> get_file_path f

and get_file_path f =
  let p = get_project f.f_project in
  get_path (Project p) ^ dir_sep ^ f.f_name

let get_all_projects_path () =
  List.map (fun p -> get_path (Project p)) (get_projects ())

let get_file_location file =
  let p = get_project file.f_project in
  get_path (Project p)

let get_dirtree_from_path path =
  let dl = Myparser.split path dir_sep.[0] in
  let rec aux cd dl =
    match dl with
    | [] -> Directory cd
    | n::[] when intern_exists_dir cd n -> intern_find_dir cd n
    | n::l when intern_exists_dir cd n ->
      begin match intern_find_dir cd n with
      | Directory d -> aux d l
      | _ -> raise (Bad_path path) end
    | _ -> raise (Bad_path path) in
  match !workspace with
  | None -> raise Workspace_closed
  | Some w ->
    begin try if List.hd dl <> w.dir_name then assert false
      with _ -> raise (Bad_path path) end;
    aux w (List.tl dl)

let get_project_from_path path =
  match get_dirtree_from_path path with
  | Directory _ -> raise (Bad_path path)
  | Project p -> p
  | File _ -> assert false

let get_file_from_path path =
  let pos = String.rindex path dir_sep.[0] in
  let ppath = String.sub path 0 pos in
  let fname = String.sub path (pos+1) (String.length path - pos - 1) in
  try
    let p = get_project_from_path ppath in
    List.find (fun f -> f.f_name = fname) p.p_files
  with _ -> raise (Bad_path path)

let get_directory_from_path path =
  match get_dirtree_from_path path with
  | Directory d -> d
  | Project _ -> raise (Bad_path path)
    | File _ -> assert false

let count_opened_files () =
  !nb_files_opened

let count_unsaved_files () =
  Hashtbl.fold (fun _ f n -> if f.f_is_unsaved then n+1 else n) existing_files 0


let is_letter c = (c > 64 && c < 91) || (c > 96 && c < 123)
let is_number c = c > 47 && c < 58
let is_underscore c = c = 95
let verify_module_name s =
  if String.length s = 0 then
    raise (Invalid_argument "A module name must have at least one character");
  if not (is_letter (Char.code s.[0])) then
    raise (Invalid_argument "A module name must begin with a letter [a-zA-Z]");
  String.iter (fun c ->
    let i = Char.code c in
    if not (is_letter i || is_number i || is_underscore i) then
      raise (Invalid_argument "A module name can only contains those characters : letters, numbers and underscore [0-9a-zA-Z_]")) s

let verify_file_name s =
  verify_module_name (Filename.chop_extension s);
  let ext = Filename.check_suffix s in
  if not (ext "ml" || ext "mli" || ext "mll" || ext "mly") then
    raise (Invalid_argument "A file name must have an \"ml\" or \"mli\" or \"mll\" or \"mly\"
  extension")

let verify_archive_name s =
  if not (Filename.check_suffix s ".tar.gz") then
      raise (Invalid_argument "File must be a \".tar.gz\" archive")

let get_prev_opened_file () =
  match !opened_file_order with
    [] -> None
  | f::_ -> Some f

let get_content file =
  try
    let es = Hashtbl.find file_content file.f_id in
    Some (Js.to_string (es##getDocument()##getValue()))
  with Not_found -> None


let get_type_of_file f =
  let ext = Filename.check_suffix f.f_name in
  if ext "ml" then Module
  else if ext "mli" then Interface
  else if ext "cma" then Library
  else if ext "mll" then Lexer
  else if ext "mly" then Grammar
  else
    let p = get_project (f.f_project) in
    raise (Bad_file_name (p, f.f_name))

let get_extension_of_type = function
  | Module -> ".ml"
  | Interface -> ".mli"
  | Library -> ".cma"
  | Lexer -> ".mll"
  | Grammar -> ".mly"

let get_edit_settings () = !edit_settings




(** ********************************** **)

let open_workspace callback () =
  match !workspace with
  | None ->
    let callback s_root =
      let w = intern_create_workspace s_root in
        intern_set_welcome_session ();
        (* Load edit settings *)
        let path = get_path (Directory w) in
        let name = "edit.settings" in
        let failure _ =
          let callback _ = callback w in
          let content = generate_of_conf
            (generate_of_edit_conf default_edit_settings) in
            Request.save_conf ~callback ~path ~name ~content
        in
        let callback str =
          edit_settings := parse_to_edit_conf (parse_to_conf str);
          intern_update_editor_theme ();
          callback w
        in
          Request.load_conf ~callback ~failure ~path ~name;
          let callback libs =
            lib_list := libs in
            Request.load_lib ~callback
    in
      Request.get_workspace ~callback
  | Some _ ->
    raise Workspace_already_opened

let open_file callback file =
  if not file.f_is_open then
    let callback str =
      file.f_is_open <- true;
      incr nb_files_opened;
      opened_file_order := file::!opened_file_order;
      let es = Ace.createEditSession str "ace/mode/ocaml" in
      Hashtbl.add file_content file.f_id es;
      (Global.editor())##setReadOnly(Js._false);
      callback (file, str)
    in
    let path = get_file_location file in
    Request.get_file_content ~callback ~path ~name:file.f_name

let save_file callback file =
  let content =  match get_content file with
    | Some s -> s
    | None -> "" in
  let callback () =
    file.f_is_unsaved <- false;
    callback file in
  let path = get_file_location file in
  Request.save_file ~callback ~path ~name:file.f_name ~content

let save_conf callback (conftype, conf) =
  let path = match conftype with
    | Compile p -> get_path (Project p)
    | Edit -> get_path (Directory (get_workspace ())) in
  let name = match conftype with
    | Compile _ -> ".webuild"
    | Edit -> "edit.settings" in
  let content = Myparser.generate_of_conf conf in
  let callback () =
    begin match conftype with
    | Compile p ->
      let conf = Myparser.parse_to_compile_conf conf in
      p.p_compile_opts <- conf
    | Edit ->
      let conf = Myparser.parse_to_edit_conf conf in
      edit_settings := conf;
      intern_update_editor_theme ()
    end;
    callback (conftype, conf) in
  Request.save_conf ~callback ~path ~name ~content


let unsave_file callback file =
  if not file.f_is_unsaved then
    (file.f_is_unsaved <- true;
     callback file)

let create_project callback (dir, name) =
  if can_create_dir dir name then
    let callback () =
      let p = intern_create_project dir name in
      callback p in
    let path = get_path (Directory dir) in
    Request.create_project callback path name
  else raise (Bad_directory_name (dir, name))

let create_directory callback (dir, name) =
  if can_create_dir dir name then
    let callback () =
      let d = intern_create_directory dir name in
      callback d in
    let path = get_path (Directory dir) in
    Request.create_directory callback path name
  else raise (Bad_directory_name (dir, name))

let create_file callback (project, name) =
  verify_file_name name;
  if can_create_file project name then
    let callback () =
      let file = intern_create_file project name in
      file.f_is_open <- true;
      incr nb_files_opened;
      opened_file_order := file::!opened_file_order;
      let es = Ace.createEditSession (CommonMisc.initial_file_content name)
          "ace/mode/ocaml" in
      Hashtbl.add file_content file.f_id es;
      (* Generates a new compile_opts with the new file at the end *)
      let conf = Myparser.generate_of_compile_conf
        { cc_files = project.p_compile_opts.cc_files @ [name];
          cc_output = project.p_compile_opts.cc_output } in
      let callback _ = callback file in
      save_conf callback (Compile project, conf) in
    let path = get_path (Project project) in
    Request.create_file ~callback ~path ~name
  else raise (Bad_file_name (project, name))


let rename_project callback (project, newname) =
  if project.p_name <> newname then
    let dir = get_directory project.p_parent in
    if can_create_dir dir newname then
      let callback () =
        project.p_name <- newname;
	callback project in
      let path = get_path (Directory dir) in
      Request.rename_directory ~callback ~path ~name:project.p_name ~newname
    else raise (Bad_directory_name (dir, newname))

let rename_directory callback (dir, newname) =
  if dir.dir_is_root then raise (Operation_denied "Rename root");
  if dir.dir_name <> newname then
    if can_create_dir (get_directory dir.dir_parent) newname then
      let callback () =
        dir.dir_name <- newname;
	callback dir in
      let path = get_path (Directory (get_directory dir.dir_parent)) in
      Request.rename_directory ~callback ~path ~name:dir.dir_name ~newname
    else raise (Bad_directory_name (dir, newname))


let rename_file callback (file, newname) =
  if file.f_name <> newname then
    let project = get_project file.f_project in
    if can_create_file project newname then
      let callback () =
        let old = file.f_name in
	         file.f_name <- newname;
        (* Change project's compile_opts and save it *)
        let cc_files = List.rev
          (List.fold_left
             (fun acc f ->
               if f = old then newname :: acc else f :: acc)
             [] project.p_compile_opts.cc_files) in
        let conf = generate_of_compile_conf
          { cc_files; cc_output = project.p_compile_opts.cc_output } in
        let callback _ = callback file in
	save_conf callback (Compile project, conf) in
      let path = get_path (Project project) in
      Request.rename_file ~callback ~path ~name:file.f_name ~newname
    else raise (Bad_file_name (project, newname))


let opam_files = ref []

let init_opam_files () =
  let opam_dir =
    let d = {
      dir_id = 0;
      dir_parent = -1;
      dir_is_root = true;
      dir_name = "OPAM";
      dir_dirs = [];
    } in
    Hashtbl.add existing_directories d.dir_id d;
    incr dir_id;
    d
  in
  let opam_project =
    intern_add_project opam_dir "graph" [ ] "" in
  let graphics_cmi = intern_add_file opam_project "graphics.cmi" in
  let graphics_prims = intern_add_file opam_project "graphics.prims" in
  opam_files := [graphics_cmi; graphics_prims]

let _ = init_opam_files ()

let close_workspace callback () =
  match !workspace with
  | None -> ()
  | Some w ->
    workspace := None;
    f_id := 0;
    p_id := 0;
    dir_id := 0;
    current_file := None;
    nb_files_opened := 0;
    opened_file_order := [];
    lib_list := [];
    Hashtbl.reset file_content;
    Hashtbl.reset existing_projects;
    Hashtbl.reset existing_files;
    Hashtbl.reset existing_directories;
    (Global.editor ())##setValue(Js.string "");
    init_opam_files ();
    callback ()

let close_file callback file =
  file.f_is_open <- false;
  file.f_is_unsaved <- false;
  decr nb_files_opened;
  if !nb_files_opened = 0 then intern_set_welcome_session ();
  opened_file_order := List.filter (fun f -> f.f_id <> file.f_id)
    !opened_file_order;
  Hashtbl.remove file_content file.f_id;
  begin match !current_file with
  | Some f when file.f_id = f.f_id -> current_file := None
  | _ -> ()
  end;
  callback file


let delete_file callback file =
  let project = get_project file.f_project in
  let callback () =
    intern_delete_file file;
    (* Change the project's compile_opts *)
    let cc_files = List.filter (fun f -> f <> file.f_name)
      project.p_compile_opts.cc_files in
    let conf = generate_of_compile_conf
      { cc_files ; cc_output = project.p_compile_opts.cc_output } in
    let callback _ = callback file in
    save_conf callback (Compile project, conf) in
  let path = get_file_location file in
  Request.delete_file ~callback ~path ~name:file.f_name

let delete_project callback project =
  let callback () =
    intern_delete_project project;
    callback project in
  let path = get_path (Directory (get_directory project.p_parent)) in
  Request.delete_directory ~callback ~path ~name:project.p_name

let delete_directory callback dir =
  if dir.dir_is_root then raise (Operation_denied "Delete Root");
  let callback () =
    intern_delete_directory dir;
    callback dir in
  let path = get_path (Directory (get_directory dir.dir_parent)) in
  Request.delete_directory ~callback ~path ~name:dir.dir_name

let import_project callback (dir, name, content) =
  let basename = Filename.chop_suffix name ".tar.gz" in
  let rec rename name cpt =
    let n = name ^ (string_of_int cpt) in
    if not (can_create_dir dir n) then rename name (cpt+1)
    else n in
  let basename =
    if not (can_create_dir dir basename) then rename basename 1
    else basename in
  let name = basename ^ ".tar.gz" in
  let callback p =
    let project = match p with
      | S_Project (n, fl, opts) -> intern_add_project dir n fl opts
      | _ -> assert false
    in
    callback project
  in
  let path = get_path (Directory dir) in
  Request.import_project ~callback ~path ~file:name ~content


let import_file callback (project, name, content) =
  let content = Myutils.my_decode content in
  let ext = Filename.check_suffix name in
  let ext = if ext "ml" then ".ml"
    else if ext "mli" then ".mli"
    else if ext "mll" then ".mll"
    else if ext "mly" then ".mly"
    else assert false in
  let name = Filename.chop_extension name in
  let rec rename file cpt =
    let f = file ^ (string_of_int cpt) in
    if not (can_create_file project f) then rename file (cpt+1)
    else f in
  let name =
    if not (can_create_file project name) then rename name 1
    else name in
  let name = name ^ ext in
  let callback () =
    (* Create file *)
    let file = intern_create_file project name in
    file.f_is_open <- true;
    incr nb_files_opened;
    opened_file_order := file::!opened_file_order;
    (* Add its content *)
    let es = Ace.createEditSession "" "ace/mode/ocaml" in
    es##getDocument()##setValue(Js.string content);
    Hashtbl.add file_content file.f_id es;
    (* Change project's compile_opts with the new file at the end *)
    let conf = generate_of_compile_conf
      { cc_files = project.p_compile_opts.cc_files @ [name];
        cc_output = project.p_compile_opts.cc_output } in
    let callback _ = callback file in
    save_conf callback (Compile project, conf) in
  let path = get_path (Project project) in
  Request.import_file ~callback ~path ~name ~content


let switch_file callback file =
  let old_file = !current_file in
  let do_it () =
    opened_file_order := file::(List.filter (fun f -> f.f_id <> file.f_id)
				    !opened_file_order);
    current_file := Some file;
    let es =
      try Hashtbl.find file_content file.f_id
      with _ -> failwith "Filemanager : file_content Not Found" in
    (Global.editor())##setSession(es);
    callback (old_file, file) in

  match old_file with
  | None -> do_it ()
  | Some old_file when file.f_id <> old_file.f_id -> do_it ()
  | _ -> ()


let link_before callback file =
  let p, filename = (get_project file.f_project), file.f_name in
  let cc_files = List.rev
    (List.fold_left
       (fun acc f ->
         if f = filename then
           if List.length acc = 0 then [f]
           else (List.hd acc) :: f :: (List.tl acc)
         else f :: acc)
       [] p.p_compile_opts.cc_files) in
  let cc_output = p.p_compile_opts.cc_output in
  let conf = generate_of_compile_conf { cc_files; cc_output } in
  callback (Compile p, conf, file)


let link_after callback file =
  let p, filename = (get_project file.f_project), file.f_name in
  let cc_files = List.fold_left
    (fun acc f ->
      if f = filename then
        if List.length acc = 0 then [f]
        else (List.hd acc) :: f :: (List.tl acc)
      else f :: acc)
    [] (List.rev p.p_compile_opts.cc_files) in
  let cc_output = p.p_compile_opts.cc_output in
  let conf = generate_of_compile_conf { cc_files; cc_output } in
  callback (Compile p, conf, file)

let compile callback project =
  let path = get_path (Project project) in
    Request.compile_project callback path project.p_compile_opts.cc_output


(*let compile callback project =
  let cconf = project.p_compile_opts in
  let comp_tbl = Hashtbl.create 19 in

  let p_files = !opam_files @ project.p_files in

  (* Generate the file list with their content and send them for compiling *)
  let callback_onload () =
    let src = List.rev (List.fold_left (fun acc file ->
      let name = file.f_name in
      let content = match get_content file with
        | Some s -> s
        | None -> try
          Hashtbl.find comp_tbl name
        with Not_found ->
          Printf.kprintf failwith "compile.callback_onload %S" name
      in
      (name, content)::acc) [] p_files) in
    let cconf = Mycompile.({ co_path = get_path (Project project);
                             co_src = src;
                             co_output = cconf.cc_output }) in
    Mycompile.compile callback cconf in
  (* Call this function when the content have to be loaded from the server.
     It also counts if all files have been loaded and if that's the case,
     calls [callback_onload] *)
  let file_number = ref (List.length p_files (*cconf.cc_files*) ) in
  let get_file_content file =
    let callback c =
      Hashtbl.add comp_tbl file.f_name c;
      (* We don't keep unloaded file content in filemanager *)
      decr file_number;
      if !file_number <= 0 then callback_onload ()
    in
    let path = get_file_location file in
    Request.get_file_content ~callback ~path ~name:file.f_name in
  (* Verify if each content file is known and call [callback_onload],
     otherwise call [get_file_content] (which will call [callback_onload]
     if necessary) *)
  List.iter (fun file ->
    match get_content file with
    | Some s ->
      Hashtbl.add comp_tbl file.f_name s;
      decr file_number;
      if !file_number <= 0 then callback_onload ()
    | None -> get_file_content file)
    p_files*)

let import_library callback (project, library) =
  let check_list = List.map (fun file -> file.f_name = library) project.p_files in
    if List.mem true check_list then ()
    else 
      let path = get_path (Project project) in
      let callback () =
        let file = intern_create_file project library in
          callback file;
          let conf = Myparser.generate_of_compile_conf
            { cc_files = project.p_compile_opts.cc_files @ [library];
              cc_output = project.p_compile_opts.cc_output } in
            save_conf (fun _ -> ()) (Compile project, conf)
      in
        Request.install_lib ~callback ~path ~library