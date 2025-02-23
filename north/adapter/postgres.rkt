#lang at-exp racket/base

(require db
         net/url
         racket/contract/base
         racket/format
         racket/match
         "base.rkt")

(provide
 (contract-out
  [struct postgres-adapter ([conn connection?])]
  [url->postgres-adapter (-> url? adapter?)]))

(define CREATE-SCHEMA-TABLE #<<EOQ
CREATE TABLE IF NOT EXISTS north_schema_version(
  current_revision TEXT NOT NULL
) WITH (
  fillfactor = 10
);
EOQ
)

(struct postgres-adapter (conn)
  #:methods gen:adapter
  [(define (adapter-init ad)
     (define conn (postgres-adapter-conn ad))
     (call-with-transaction conn
       (lambda ()
         (log-north-adapter-debug "creating schema table")
         (query-exec conn CREATE-SCHEMA-TABLE))))

   (define (adapter-current-revision ad)
     (define conn (postgres-adapter-conn ad))
     (query-maybe-value conn "SELECT current_revision FROM north_schema_version"))

   (define (adapter-apply! ad revision scripts)
     (define conn (postgres-adapter-conn ad))
     (with-handlers ([exn:fail:sql?
                      (lambda (e)
                        (raise (exn:fail:adapter:migration @~a{failed to apply revision '@revision'}
                                                           (current-continuation-marks) e revision)))])
       (call-with-transaction conn
         (lambda ()
           (log-north-adapter-debug "applying revision ~a" revision)
           (for ([script (in-list scripts)])
             (query-exec conn script))

           (query-exec conn "DELETE FROM north_schema_version")
           (query-exec conn "INSERT INTO north_schema_version VALUES ($1)" revision)))))])

(define (url->postgres-adapter url)
  (define (oops message)
    (raise
     (exn:fail:adapter
      (~a message
          "\n connection URLs must have the form:"
          "\n  postgres://[username[:password]@]hostname[:port]/database_name")
      (current-continuation-marks)
      #f)))
  (define host (url-host url))
  (when (string=? host "")
    (oops "host missing"))
  (define path (url-path url))
  (when (null? path)
    (oops "database_name missing"))
  (define database
    (path/param-path (car (url-path url))))
  (match-define (list _ username password)
    (regexp-match #px"([^:]+)(?::(.+))?" (or (url-user url) "root")))

  (postgres-adapter
   (postgresql-connect #:database database
                       #:server host
                       #:port (url-port url)
                       #:user username
                       #:password password)))
