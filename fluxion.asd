;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Live server-rendered interfaces for Common Lisp

(defsystem "fluxion"
  :name "fluxion"
  :version "1.0.0"
  :author "Glenn Thompson"
  :licence "MIT"
  :description "A Common Lisp framework for live, server-driven reactive web interfaces built around CLOS."
  :depends-on ("alexandria"
               "spinneret"
               "clack"
               "lack"
               "cl-json"
               "babel"
               "ironclad"
               "bordeaux-threads"
               "hunchentoot"
               "clack-handler-woo"
               "cl-ppcre")
  :serial t
  :components
  ((:module "src"
    :serial t
    :components
    ((:file "package")
     (:file "protocol")
     (:file "events")
     (:file "signals")
     (:file "components")
     (:file "cells")
     (:file "render")
     (:file "validation")
     (:file "conditions")
     (:file "csrf")
     (:file "event-queue")
     (:file "session")
     (:file "auth")
     (:file "app")
     (:file "middleware")
     (:file "router")
     (:file "reaper")
     (:file "handler")))))

(defsystem "fluxion/tests"
  :name "fluxion-tests"
  :version "0.1.0"
  :description "Test suite for Fluxion."
  :depends-on ("fluxion" "fluxion/client" "fiveam" "dexador" "usocket")
  :serial t
  :components
  ((:module "tests"
    :serial t
    :components
    ((:file "package")
     (:file "test-protocol")
     (:file "test-events")
     (:file "test-cells")
     (:file "test-computed")
     (:file "test-transactions")
     (:file "test-thread-safety")
     (:file "test-session-reaper")
     (:file "test-propagators")
     (:file "test-convergence")
     (:file "test-middleware")
     (:file "test-lifecycle")
     (:file "test-composition")
     (:file "test-components")
     (:file "test-server")
     (:file "test-router")
     (:file "test-validation")
     (:file "test-observability")
     (:file "test-integration")))))

(defsystem "fluxion/client"
  :name "fluxion-client"
  :version "0.1.0"
  :description "Parenscript browser runtime for Fluxion."
  :depends-on ("parenscript" "fluxion")
  :serial t
  :components
  ((:module "client"
    :serial t
    :components
    ((:file "package")
     (:file "runtime")))))

(defsystem "fluxion/examples"
  :name "fluxion-examples"
  :version "0.1.0"
  :description "Example applications for Fluxion."
  :depends-on ("fluxion" "fluxion/client")
  :serial t
  :components
  ((:module "examples"
    :serial t
    :components
    ((:file "counter")
     (:file "todo")
     (:file "converter")
     (:file "colour-picker")))))
