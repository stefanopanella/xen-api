open Pervasiveext
open Client
open Forkhelpers
open Xapi_templates
open Attach_helpers

module D = Debug.Debugger(struct let name="xapi" end)
open D

(** Execute the post install script of 'vm' having attached all the vbds to the 'install_vm' *)
let post_install_script rpc session_id __context install_vm vm (script, vbds) = 
  (* Cancellable task *)
  TaskHelper.set_cancellable ~__context;

  let refresh_session = Xapi_session.consider_touching_session rpc session_id in

  match script with
  | None -> () (* nothing to do *)
  | Some script ->
      let vdis = List.map (fun self -> Client.VBD.get_VDI rpc session_id self) vbds in
      let uuids = List.map (fun self -> Uuid.of_string (Client.VDI.get_uuid rpc session_id self)) vdis in
      with_vbds rpc session_id __context install_vm vdis `RW
	(fun install_vm_vbds ->
	   let devices = List.map 
	     (fun (install_vm_vbd, vbd) ->
		let hvm = Client.VM.get_HVM_boot_policy rpc session_id vm <> "" in
		let device = Vbdops.translate_vbd_device (Client.VBD.get_userdevice rpc session_id vbd) hvm in
		device,
		"/dev/" ^ (Client.VBD.get_device rpc session_id install_vm_vbd)) (List.combine install_vm_vbds vbds) in
	   let env = ("vm", Ref.string_of vm) :: devices in
	   let env = List.map (fun (k, v) -> k ^ "=" ^ v) env in
	   debug "Executing script %s with env %s" script (String.concat "; " env);

	   match with_logfile_fd "install-log"
	     (fun log ->
	       let pid = safe_close_and_exec ~env:(Array.of_list env)
		 [ Dup2(log, Unix.stdout);
		   Dup2(log, Unix.stderr) ]
		 [ Unix.stdout; Unix.stderr ]
		 script [] in
	       let starttime = Unix.time () in
	       let rec update_progress () =
		 (* Check for cancelling *)
		 if TaskHelper.is_cancelling ~__context
		 then
		   begin
		     Unix.kill pid Sys.sigterm;
		     let _ = Unix.waitpid [] pid in
		     raise (Api_errors.Server_error (Api_errors.task_cancelled, []))
		   end;
		 
		 let (newpid,status) = Unix.waitpid [Unix.WNOHANG] pid in
		 if newpid = pid 
		 then 
		   (match status with 
		     | Unix.WEXITED 0 -> (newpid,status) 
		     | Unix.WEXITED n -> raise (Subprocess_failed n))
		 else		 
		   begin
		     Thread.delay 1.0;
		     refresh_session ();
		     let curtime = Unix.time () in
		     let elapsed = curtime -. starttime in
		     let f x = 0.1 +. (0.9 -. 0.9 *. exp (-. elapsed /. 60.0)) in
		     let progress = f elapsed in
		     TaskHelper.set_progress ~__context progress;
		     update_progress ()
		   end
	       in update_progress ()
	     ) with
	       | Success _ -> debug "Install script exitted successfully."
	       | Failure(log, Subprocess_failed n) ->
		   error "post_install_script failed: message='%s' (assuming this was because the disk was too small)" log;
		   raise (Api_errors.Server_error (Api_errors.provision_failed_out_of_space, []))
	       | Failure(log, exn) ->
		   raise exn
	)
       
	
