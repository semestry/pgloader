;;;
;;; Generic API for pgloader sources
;;; Methods for source types with multiple files input
;;;

(in-package :pgloader.sources)

(defmethod parse-header ((copy md-copy) header)
  "Unsupported by default, to be implemented in each md-copy subclass."
  (error "Parsing the header of a ~s is not implemented yet." (type-of copy)))

(defmethod map-rows ((copy md-copy) &key process-row-fn)
  "Load data from a text file in CSV format, with support for advanced
   projecting capabilities. See `project-fields' for details.

   Each row is pre-processed then PROCESS-ROW-FN is called with the row as a
   list as its only parameter.

   Finally returns how many rows where read and processed."

  (with-connection (cnx (source copy)
                        :direction :input
                        :external-format (encoding copy)
                        :if-does-not-exist nil)
    (let ((input (md-strm cnx)))
     ;; we handle skipping more than one line here, as cl-copy only knows
     ;; about skipping the first line
      (loop :repeat (skip-lines copy) :do (read-line input nil nil))

      ;; we might now have to read the fields from the header line
      (when (header copy)
        (setf (fields copy)
              (parse-header copy (read-line input nil nil)))

        (log-message :debug "Parsed header columns ~s" (fields copy)))

      ;; read in the text file, split it into columns
      (process-rows copy input process-row-fn))))

(defmethod preprocess-row ((copy md-copy))
  "The file based readers possibly have extra work to do with user defined
   fields to columns projections (mapping)."
  (reformat-then-process :fields  (fields copy)
                         :columns (columns copy)
                         :target  (target copy)))

(defmethod copy-column-list ((copy md-copy))
  "We did reformat-then-process the column list, so we now send them in the
   COPY buffer as found in (columns fixed)."
  (mapcar (lambda (col)
            ;; always double quote column names
            (format nil "~s" (car col)))
          (columns copy)))

(defmethod clone-copy-for ((copy md-copy) path-spec)
  "Create a copy of CSV for loading data from PATH-SPEC."
  (make-instance (class-of copy)
                 ;; source-db is expected unbound here, so bypassed
                 :target-db  (clone-connection (target-db copy))
                 :source     (make-instance (class-of (source copy))
                                            :spec (md-spec (source copy))
                                            :type (conn-type (source copy))
                                            :path path-spec)
                 :target     (target copy)
                 :fields     (fields copy)
                 :columns    (columns copy)
                 :transforms (transforms copy)
                 :encoding   (encoding copy)
                 :skip-lines (skip-lines copy)
                 :header     (header copy)))

(defmethod copy-database ((copy md-copy)
                          &key
                            truncate
                            disable-triggers
			    drop-indexes

                            ;; generic API, but ignored here
                            (worker-count 4)
                            (concurrency 1)

                            data-only
			    schema-only
                            create-tables
			    include-drop
                            foreign-keys
			    create-indexes
			    reset-sequences
                            materialize-views
                            set-table-oids
                            including
                            excluding)
  "Copy the contents of the COPY formated file to PostgreSQL."
  (declare (ignore data-only schema-only
                   create-tables include-drop foreign-keys
                   create-indexes reset-sequences materialize-views
                   set-table-oids including excluding))

  ;; this sets (table-index-list (target copy))
  (maybe-drop-indexes (target-db copy)
                      (target copy)
                      :drop-indexes drop-indexes)

  ;; ensure we truncate only one
  (when truncate
    (truncate-tables (clone-connection (target-db copy)) (target copy)))

  ;; expand the specs of our source, we might have to care about several
  ;; files actually.
  (let* ((lp:*kernel* (make-kernel worker-count))
         (channel     (lp:make-channel))
         (path-list   (expand-spec (source copy))))
    (loop :for path-spec :in path-list
       :do (let ((table-source (clone-copy-for copy path-spec)))
             (copy-from table-source
                        :concurrency concurrency
                        :kernel lp:*kernel*
                        :channel channel
                        :truncate nil
                        :disable-triggers disable-triggers)))

    ;; end kernel
    (with-stats-collection ("COPY Threads Completion" :section :post
                                                      :use-result-as-read t
                                                      :use-result-as-rows t)
        (let ((worker-count (* (length path-list)
                               (task-count concurrency))))
          (loop :for tasks :below worker-count
             :do (destructuring-bind (task table seconds)
                     (lp:receive-result channel)
                   (log-message :debug
                                "Finished processing ~a for ~s ~50T~6$s"
                                task (format-table-name table) seconds)
                   (when (eq :writer task)
                     (update-stats :data table :secs seconds))))
          (prog1
              worker-count
            (lp:end-kernel :wait nil))))
    (lp:end-kernel :wait t))

  ;; re-create the indexes from the target table entry
  (create-indexes-again (target-db copy)
                        (target copy)
                        :drop-indexes drop-indexes))