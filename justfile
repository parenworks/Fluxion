# Fluxion - Common Lisp reactive web framework
# Usage: just <recipe>

fluxion_path := justfile_directory() + "/"
sbcl := "sbcl --noinform"

# Default recipe - show available commands
default:
    @just --list

# Compile all systems (check for errors)
check:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion)' \
      --eval '(asdf:load-system :fluxion/client)' \
      --eval '(asdf:load-system :fluxion/db-pg)' \
      --eval '(asdf:load-system :fluxion/rdb)' \
      --eval '(asdf:load-system :fluxion/session-db)' \
      --eval '(asdf:load-system :fluxion/user)' \
      --eval '(asdf:load-system :fluxion/auth)' \
      --eval '(asdf:load-system :fluxion/ban)' \
      --eval '(asdf:load-system :fluxion/rate)' \
      --eval '(asdf:load-system :fluxion/cache)' \
      --eval '(asdf:load-system :fluxion/mail)' \
      --eval '(asdf:load-system :fluxion/profile)' \
      --eval '(asdf:load-system :fluxion/hooks)' \
      --eval '(asdf:load-system :fluxion/log)' \
      --eval '(asdf:load-system :fluxion/migrate)' \
      --eval '(format t "~%Fluxion compiled successfully.~%")'

# Run core tests (no database required)
test:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion/tests)' \
      --eval '(5am:run! (quote fluxion.tests::fluxion-suite))'

# Run database tests (requires SQLite)
test-db:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion/db-tests)' \
      --eval '(5am:run! :db-suite)'

# Run PostgreSQL-specific tests (requires running PostgreSQL)
test-pg:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion/db-pg-tests)' \
      --eval '(5am:run! :db-pg-suite)'

# Run all tests
test-all: test test-db

# Run load tests
load-test:
    {{sbcl}} --load tests/load-test.lisp

# Generate API.md from live introspection
docs:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion)' \
      --eval '(asdf:load-system :fluxion/client)' \
      --eval '(asdf:load-system :fluxion/db-pg)' \
      --eval '(asdf:load-system :fluxion/rdb)' \
      --eval '(asdf:load-system :fluxion/session-db)' \
      --eval '(asdf:load-system :fluxion/user)' \
      --eval '(asdf:load-system :fluxion/auth)' \
      --eval '(asdf:load-system :fluxion/ban)' \
      --eval '(asdf:load-system :fluxion/rate)' \
      --eval '(asdf:load-system :fluxion/cache)' \
      --eval '(asdf:load-system :fluxion/mail)' \
      --eval '(asdf:load-system :fluxion/profile)' \
      --eval '(asdf:load-system :fluxion/hooks)' \
      --eval '(asdf:load-system :fluxion/log)' \
      --eval '(asdf:load-system :fluxion/migrate)' \
      --eval '(load "tools/generate-docs.lisp")' \
      --eval '(fluxion.docs:generate)'

# Build the client runtime JS
build-client:
    {{sbcl}} --non-interactive \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion/client)' \
      --eval '(fluxion.client:build-client)'

# Run Observatory example (port 5222)
example-observatory:
    {{sbcl}} \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(push #P"../Observatory/" asdf:*central-registry*)' \
      --eval '(ql:quickload :observatory)' \
      --eval '(observatory:start :port 5222)'

# REPL with all systems loaded
repl:
    {{sbcl}} \
      --eval '(require :asdf)' \
      --eval '(push #P"{{fluxion_path}}" asdf:*central-registry*)' \
      --eval '(asdf:load-system :fluxion)' \
      --eval '(asdf:load-system :fluxion/client)' \
      --eval '(asdf:load-system :fluxion/hooks)' \
      --eval '(asdf:load-system :fluxion/log)' \
      --eval '(in-package :fluxion)'

# Clean compiled FASL files
clean:
    find . -name "*.fasl" -delete
    @echo "Cleaned FASL files."
