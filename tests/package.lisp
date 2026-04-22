;;;; -*- encoding:utf-8 -*-
;;;; Fluxion test suite - package definition

(defpackage #:fluxion.tests
  (:use #:cl #:fiveam)
  (:shadow #:run-all-tests)
  (:export #:run-all-tests))

(in-package #:fluxion.tests)

(def-suite fluxion-suite
  :description "Top-level suite for all Fluxion tests.")

(def-suite protocol-suite
  :description "SSE protocol formatting."
  :in fluxion-suite)

(def-suite events-suite
  :description "Event constructors."
  :in fluxion-suite)

(def-suite cells-suite
  :description "Reactive cells."
  :in fluxion-suite)

(def-suite computed-suite
  :description "Computed cells with dependency tracking."
  :in fluxion-suite)

(def-suite propagators-suite
  :description "Propagators and bidirectional constraints."
  :in fluxion-suite)

(def-suite components-suite
  :description "CLOS component model, defaction, defcomponent."
  :in fluxion-suite)

(def-suite server-suite
  :description "Server, sessions, event queue, SSE push."
  :in fluxion-suite)

(def-suite router-suite
  :description "Path-based routing."
  :in fluxion-suite)

(def-suite validation-suite
  :description "Form validation helpers."
  :in fluxion-suite)

(defun run-all-tests ()
  "Run the full Fluxion test suite. Returns T if all tests pass."
  (run! 'fluxion-suite))
