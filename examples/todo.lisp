;;;; -*- encoding:utf-8 -*-
;;;; Fluxion Example - Todo List
;;;;
;;;; Demonstrates:
;;;;   - Per-session component state
;;;;   - Form submission with data-on-keydown
;;;;   - Checkbox toggling with data-on-change
;;;;   - Element-specific params with data-param-*
;;;;   - Confirmation dialogs with data-confirm
;;;;   - data-disable-during-request for click deduplication
;;;;   - Router-based page serving
;;;;
;;;; Usage:
;;;;   (ql:quickload :fluxion/examples)
;;;;   (fluxion.examples.todo:start-todo)
;;;;   ;; Open http://localhost:5000

(defpackage #:fluxion.examples.todo
  (:use #:cl #:fluxion)
  (:export #:start-todo
           #:stop-todo))

(in-package #:fluxion.examples.todo)

;;; -------------------------------------------------------
;;; Todo item model
;;; -------------------------------------------------------

(defclass todo-item ()
  ((id    :initarg :id    :accessor todo-id    :type string)
   (text  :initarg :text  :accessor todo-text  :type string)
   (done  :initarg :done  :accessor todo-done  :initform nil :type boolean)))

(defun make-todo (text)
  "Create a new todo item with a unique ID."
  (make-instance 'todo-item
    :id (format nil "todo-~A" (random (expt 2 48)))
    :text text
    :done nil))

;;; -------------------------------------------------------
;;; Component
;;; -------------------------------------------------------

(defclass todo-list (component)
  ((items :initform nil :accessor todo-items))
  (:default-initargs :id "todo-list"))

(defun find-todo (comp id)
  "Find a todo item by ID."
  (find id (todo-items comp) :key #'todo-id :test #'string=))

;;; -------------------------------------------------------
;;; Render
;;; -------------------------------------------------------

(defmethod render ((c todo-list))
  (let ((items (todo-items c))
        (done-count (count-if #'todo-done (todo-items c)))
        (total (length (todo-items c))))
    (spinneret:with-html-string
      (:div :id (component-id c)
            :class "todo-component"
        (:h2 "Todo List")

        ;; Input for new todos
        (:div :class "todo-input"
          (:input :type "text"
                  :placeholder "What needs to be done?"
                  :data-on-keydown "/action/todo-list/add"
                  :data-key "Enter"
                  :autofocus t))

        ;; Stats bar
        (when (plusp total)
          (:div :class "todo-stats"
            (:span (format nil "~D of ~D done" done-count total))
            (when (plusp done-count)
              (:button :data-on-click "/action/todo-list/clear-done"
                       :data-confirm "Remove all completed items?"
                       :data-disable-during-request t
                       :class "clear-btn"
                       "Clear completed"))))

        ;; Todo items
        (if items
            (:ul :class "todo-items"
              (dolist (item items)
                (:li :class (if (todo-done item) "todo-item done" "todo-item")
                     :id (todo-id item)
                  (:input :type "checkbox"
                          :data-on-change "/action/todo-list/toggle"
                          :data-param-id (todo-id item)
                          :checked (todo-done item))
                  (:span :class "todo-text" (todo-text item))
                  (:button :class "delete-btn"
                           :data-on-click "/action/todo-list/delete"
                           :data-param-id (todo-id item)
                           "x"))))
            (:p :class "empty-message" "No todos yet. Add one above!"))))))

;;; -------------------------------------------------------
;;; Actions
;;; -------------------------------------------------------

(defaction todo-list :add (c params)
  (let ((value (cdr (assoc :value params))))
    (when (and value (plusp (length (string-trim " " value))))
      (push (make-todo (string-trim " " value)) (todo-items c))))
  (append (patch-component c)
          (list (make-script-event
                 "var el = document.querySelector('#todo-list [data-on-keydown]'); if(el) el.value = '';"))))

(defaction todo-list :toggle (c params)
  (let* ((id (cdr (assoc :id params)))
         (item (and id (find-todo c id))))
    (when item
      (setf (todo-done item) (not (todo-done item)))))
  nil)

(defaction todo-list :delete (c params)
  (let ((id (cdr (assoc :id params))))
    (when id
      (setf (todo-items c)
            (remove id (todo-items c) :key #'todo-id :test #'string=))))
  nil)

(defaction todo-list :clear-done (c)
  (setf (todo-items c)
        (remove-if #'todo-done (todo-items c)))
  nil)

;;; -------------------------------------------------------
;;; Page
;;; -------------------------------------------------------

(defun render-todo-page (todo-list &key csrf-token)
  (render-page
   :title "Fluxion Todo List"
   :csrf-token csrf-token
   :body-html
   (concatenate 'string
    "<style>
       body { font-family: system-ui, sans-serif; max-width: 600px; margin: 2rem auto; padding: 0 1rem;
              background: #fafafa; color: #333; }
       h1 { color: #333; margin-bottom: 0.25rem; }
       h1 + p { color: #666; margin-top: 0; }
       .todo-component { background: #fff; border: 1px solid #e0e0e0; border-radius: 8px;
                          padding: 1.5rem; box-shadow: 0 2px 4px rgba(0,0,0,0.05); }
       .todo-component h2 { margin-top: 0; }
       .todo-input input { width: 100%; padding: 0.75rem; border: 2px solid #e0e0e0; border-radius: 6px;
                            font-size: 1rem; box-sizing: border-box; transition: border-color 0.2s; }
       .todo-input input:focus { outline: none; border-color: #4a90d9; }
       .todo-stats { display: flex; justify-content: space-between; align-items: center;
                      padding: 0.5rem 0; margin-top: 0.75rem; font-size: 0.9rem; color: #888; }
       .clear-btn { background: none; border: none; color: #d9534f; cursor: pointer; font-size: 0.85rem;
                     padding: 0.25rem 0.5rem; border-radius: 4px; }
       .clear-btn:hover { background: #fdf0f0; }
       .todo-items { list-style: none; padding: 0; margin: 0.75rem 0 0; }
       .todo-item { display: flex; align-items: center; gap: 0.75rem; padding: 0.6rem 0;
                     border-bottom: 1px solid #f0f0f0; }
       .todo-item:last-child { border-bottom: none; }
       .todo-item input[type=checkbox] { width: 1.1rem; height: 1.1rem; cursor: pointer; accent-color: #4a90d9; }
       .todo-text { flex: 1; }
       .todo-item.done .todo-text { text-decoration: line-through; color: #aaa; }
       .delete-btn { background: none; border: none; color: #ccc; cursor: pointer; font-size: 1.1rem;
                      padding: 0 0.4rem; border-radius: 4px; line-height: 1; }
       .delete-btn:hover { color: #d9534f; background: #fdf0f0; }
       .empty-message { color: #aaa; font-style: italic; text-align: center; padding: 1.5rem 0; }
     </style>
     <h1>Fluxion</h1>
     <p>Live server-rendered interfaces for Common Lisp.</p>"
    (render todo-list))))

;;; -------------------------------------------------------
;;; Application setup (router-based)
;;; -------------------------------------------------------

(defvar *app* nil)
(defvar *router* (make-router))

(defroute *router* :get "/" (app session env &key params)
  (declare (ignore app env params))
  (let ((todo (session-component session "todo-list")))
    (list 200
          '(:content-type "text/html")
          (list (render-todo-page todo
                 :csrf-token (session-csrf-token session))))))

(defun start-todo (&key (port 5000))
  (when *app*
    (stop *app*))

  (setf *app* (make-fluxion-app
               :port port
               :static-dir (asdf:system-relative-pathname "fluxion" "static/")))

  ;; Register factory - each session gets its own todo list
  (register-component-factory *app* "todo-list"
    (lambda () (make-instance 'todo-list)))

  ;; Build the client runtime JS
  (fluxion.client:build-client)

  ;; Start the server with the router
  (start *app* (router-handler *router*) :port port)

  (format t "~%Fluxion todo example running at http://localhost:~D~%" port)
  *app*)

(defun stop-todo ()
  (when *app*
    (stop *app*)
    (setf *app* nil)
    (format t "Fluxion todo stopped.~%")))
