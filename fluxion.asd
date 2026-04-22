;;;; -*- encoding:utf-8 -*-
;;;; Fluxion - Live server-rendered interfaces for Common Lisp

(defsystem "fluxion"
  :name "fluxion"
  :version "0.1.0"
  :author "Glenn Thompson"
  :licence "BSD-3-Clause"
  :description "A Common Lisp framework for live, server-driven reactive web interfaces built around CLOS."
  :depends-on ("alexandria"
               "spinneret"
               "clack"
               "lack"
               "cl-json"
               "babel"
               "bordeaux-threads"
               "hunchentoot")
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
     (:file "server")))))

(defsystem "fluxion/tests"
  :name "fluxion-tests"
  :version "0.1.0"
  :description "Test suite for Fluxion."
  :depends-on ("fluxion" "fluxion/client" "fiveam")
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
     (:file "test-propagators")
     (:file "test-components")
     (:file "test-server")))))

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
     (:file "converter")))))
