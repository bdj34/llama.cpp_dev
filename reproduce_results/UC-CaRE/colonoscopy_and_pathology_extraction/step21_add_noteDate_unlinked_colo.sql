use <DATABASE>;

-- Add note date for unlinked colonoscopy reports 
-- (so we have dates for all colonoscopy reports even if the report is not linked to a specific path report)
select linked.*, notes.EntryDateTime as [EntryDateTime.unlinked] 
into <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12
  from <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_04_23 as linked
  left join <SCHEMA>.NoteTable as notes
  on notes.notesDocumentSID = TRY_CAST(linked.[notesDocumentSID.unlinked] AS BIGINT)
 CREATE CLUSTERED COLUMNSTORE INDEX CCI ON <SCHEMA>.ibd_and_nonIBD_path_colo_results_2025_05_12
 -- 306,529 rows
