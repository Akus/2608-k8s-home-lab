#!/usr/bin/env bash
# Deleting the namespace deletes the PVC too; local-path's Delete reclaim policy then
# removes the data directory on the node.
kubectl delete namespace rb-02 --ignore-not-found
