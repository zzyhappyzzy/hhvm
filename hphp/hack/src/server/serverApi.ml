(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the "hack" directory of this source tree.
 *
 *)

open Core_kernel
open RemoteWorker
open Typing_service_types

let make_local_server_api
    (naming_table : Naming_table.t) ~(root : string) ~(ignore_hh_version : bool)
    : (module LocalServerApi) =
  ( module struct
    let send_progress (message : string) : unit =
      ServerProgress.send_progress_to_monitor "%s" message

    let send_percentage_progress =
      ServerProgress.send_percentage_progress_to_monitor

    let update_state ~(state_filename : string) : unit =
      let (t : int) =
        SharedMem.load_dep_table_blob state_filename ignore_hh_version
      in
      Hh_logger.log "Updated dependency graph: %d seconds" t

    let snapshot_naming_table_base ~(destination_path : string) : unit =
      send_progress "Snapshotting the naming table for delegated type checking";
      let t = Unix.gettimeofday () in
      let () =
        match Naming_table.get_forward_naming_fallback_path naming_table with
        | Some source_path ->
          Hh_logger.log
            "Updating the existing table - moving %s to %s"
            source_path
            source_path;
          FileUtil.cp [source_path] destination_path;
          let (_ : Naming_sqlite.save_result) =
            Naming_table.save naming_table destination_path
          in
          ()
        | None ->
          Hh_logger.log "Creating a new table %s" destination_path;
          let _symbols_added =
            Naming_table.save naming_table destination_path
          in
          ()
      in
      HackEventLogger.remote_scheduler_save_naming_end t;
      let (t : float) =
        Hh_logger.log_duration
          (Printf.sprintf "Saved SQLite naming table to %s" destination_path)
          t
      in
      send_progress (Printf.sprintf "Snapshotted the naming table base: %f" t)

    let snapshot_naming_table_diff ~(destination_path : string) : unit =
      Hh_logger.log "snapshot_naming_table_diff: %s" destination_path;
      Naming_table.save_changes_since_baseline naming_table ~destination_path

    let begin_get_changed_files ~(mergebase : string option) :
        string list Future.t =
      (* TODO: capture the current timestamp so it can be used for logging
        when the promise is fulfilled and retrieved. *)
      match mergebase with
      | Some mergebase -> Hg.files_changed_since_rev (Hg.Hg_rev mergebase) root
      | None -> Future.of_error "Expected a non-empty mergebase"

    let write_changed_files
        (changed_files : string list) ~(destination_path : string) : unit =
      let changed_files =
        List.map changed_files ~f:(fun changed_file ->
            let changed_file = FilePath.make_absolute root changed_file in
            let changed_file_path =
              Relative_path.create Relative_path.Root changed_file
            in
            (changed_file_path, File_provider.get_contents changed_file_path))
      in
      let chan = Pervasives.open_out_bin destination_path in
      Marshal.to_channel chan changed_files [];
      Pervasives.close_out chan
  end : LocalServerApi )

let make_remote_server_api
    (workers : MultiWorker.worker list option) (tcopt : TypecheckerOptions.t) :
    (module RemoteServerApi with type naming_table = Naming_table.t option) =
  ( module struct
    type naming_table = Naming_table.t option

    let load_naming_table_base ~(naming_table_base : Path.t option) :
        (naming_table, string) result =
      Hh_logger.log "Loading naming table base...";

      match naming_table_base with
      | None ->
        Error
          "Expected naming table base path to be set when loading naming table, but it was not"
      | Some naming_table_base ->
        Ok
          (Some
             (Naming_table.load_from_sqlite (Path.to_string naming_table_base)))

    (**
      There is a variety of state that the server accumulates after type
      checking files. We want to make sure we remove such state before a
      recheck. In order to do this cleaning, we need a list of files that
      changed.
      *)
    let clean_changed_files_state ctx naming_table changed_files ~t =
      let (changed_names : FileInfo.names) =
        List.fold changed_files ~init:FileInfo.empty_names ~f:(fun names file ->
            match Naming_table.get_file_info naming_table file with
            | Some (file_info : FileInfo.t) ->
              FileInfo.merge_names names (FileInfo.simplify file_info)
            | None -> names)
      in
      let t =
        Hh_logger.log_duration "Got names changed since naming table baseline" t
      in
      let changed_files = Relative_path.set_of_list changed_files in
      File_provider.remove_batch changed_files;
      Ast_provider.remove_batch changed_files;
      Fixme_provider.remove_batch changed_files;
      Decl_redecl_service.remove_old_defs
        ctx
        ~bucket_size:1000
        workers
        changed_names;
      Hh_logger.log_duration "Cleaned state associated with changed files" t

    let load_naming_table_changes_since_baseline
        (ctx : Provider_context.t)
        ~(naming_table : Naming_table.t option)
        ~(naming_table_diff : Naming_table.changes_since_baseline) :
        (Naming_table.t option, string) result =
      Hh_logger.log "Loading naming table changes since baseline...";
      match naming_table with
      | None -> Error "Expected naming table base"
      | Some naming_table ->
        begin
          match Naming_table.get_forward_naming_fallback_path naming_table with
          | None ->
            Error "Expected naming table base path to be set, but it was not"
          | Some naming_table_base ->
            (try
               let t = Unix.gettimeofday () in
               let changed_files =
                 Naming_table.get_files_changed_since_baseline naming_table_diff
               in
               let t =
                 Hh_logger.log_duration
                   "Got files changed since naming table baseline"
                   t
               in
               let t =
                 clean_changed_files_state ctx naming_table changed_files ~t
               in
               Hh_logger.log "Prefetching naming dirty files...";
               Vfs.prefetch changed_files;
               let t =
                 Hh_logger.log_duration "Prefetched naming dirty files" t
               in
               let (naming_table : Naming_table.t) =
                 Naming_table.load_from_sqlite_with_changes_since_baseline
                   naming_table_diff
                   naming_table_base
               in
               HackEventLogger.remote_worker_load_naming_end t;
               let _t =
                 Hh_logger.log_duration "Loaded naming table from SQLite" t
               in
               Ok (Some naming_table)
             with e -> Error (Exn.to_string e))
        end

    let type_check files_to_check ~state_filename =
      let t = Unix.gettimeofday () in
      Hh_logger.log "Type checking a batch...";
      Typing_check_service.(
        let check_info =
          {
            init_id = Random_id.short_string ();
            recheck_id = None;
            profile_log = true;
            profile_type_check_twice = false;
            profile_type_check_duration_threshold = 0.0;
          }
        in
        (* TODO: use the telemetry *)
        let (errors, _, _telemetry) =
          go
            workers
            (Typing_check_service.Delegate.create ())
            (Telemetry.create ())
            tcopt
            Relative_path.Set.empty
            files_to_check
            ~memory_cap:None
            ~check_info
        in
        HackEventLogger.remote_worker_type_check_end t;
        let t =
          Hh_logger.log_duration "Type checked files in remote worker" t
        in
        let dep_table_edges_added =
          SharedMem.save_dep_table_blob
            state_filename
            Build_id.build_revision
            ~reset_state_after_saving:true
        in
        let _t =
          Hh_logger.log_duration
            (Printf.sprintf
               "Saved partial dependency graph (%d edges)"
               dep_table_edges_added)
            t
        in
        errors)
  end : RemoteServerApi
    with type naming_table = Naming_table.t option )
