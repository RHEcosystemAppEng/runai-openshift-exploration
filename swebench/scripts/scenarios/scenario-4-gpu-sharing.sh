#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Scenario 4 — GPU sharing: heterogeneous GPU workloads competing
#
# USE CASE: the squads do not all want GPUs the same way. One squad runs a
# tensor-parallel vLLM endpoint (2 GPUs, backed by the RHOAI hardware profile
# \`${HARDWARE_PROFILE}\`); another runs several single-GPU inference replicas with
# no profile; a third runs one plain single-GPU job. This driver launches those
# heterogeneous GPU workloads so they compete for the same ResourceFlavor
# (\`${ACCELERATOR_FLAVOR}\`) and shows how the scheduler packs profile vs
# no-profile and different replica counts onto the shared pool.
#
#   bash scenario-4-gpu-sharing.sh --scheduler rhoai
#   bash scenario-4-gpu-sharing.sh --scheduler runai
# ─────────────────────────────────────────────────────────────────────────────

SCENARIO_ID=4
SCENARIO_TITLE="GPU sharing — heterogeneous GPU workloads competing (profile vs no-profile)"
# shellcheck source=_common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

print_help() {
  cat <<EOF
Scenario 4: ${SCENARIO_TITLE}
Usage: $(basename "$0") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup]

Launches three differently-shaped GPU workloads that compete for one flavor:
  - Squad A: 1 x 2-GPU job carrying the RHOAI hardware profile (${HARDWARE_PROFILE})
  - Squad B: 2 x 1-GPU jobs, no profile (inference replicas)
  - Squad C: 1 x 1-GPU job, no profile
EOF
}

# emit_profiled_job <squad> <suffix> <gpus> <hold> — like submit_gpu_job but adds
# the RHOAI hardware-profile annotation (opendatahub.io/hardware-profile-name) so
# the workload is scheduled against the \`${HARDWARE_PROFILE}\` profile's flavor.
emit_profiled_job() {
  local squad="$1" suffix="$2" gpus="$3" hold="$4"
  local ns="${SQUAD_NS[$squad]}" split="${SQUAD_SPLIT[$squad]}" prio="${SQUAD_PRIORITY[$squad]}"
  local name="scn${SCENARIO_ID}-squad-${squad}-${suffix}"
  local deadline=$(( hold + 600 ))

  local kueue_labels="" sched_line="" suspend_line="" tmpl_runai_label=""
  local anno_lines="    opendatahub.io/hardware-profile-name: ${HARDWARE_PROFILE}"
  if [[ "$SCHEDULER" == "runai" ]]; then
    sched_line="      schedulerName: ${RUNAI_SCHEDULER}"
    anno_lines="${anno_lines}
    runai/queue: \"${ns}\"
    project: \"${ns}\""
    tmpl_runai_label="$(printf '        runai/queue: "%s"' "$ns")"
  else
    kueue_labels="$(printf '    kueue.x-k8s.io/queue-name: %s\n    kueue.x-k8s.io/priority-class: %s' "$LOCAL_QUEUE" "$prio")"
    suspend_line="  suspend: true"
  fi

  log "submit ${name} (profiled: ${HARDWARE_PROFILE}) → ns=${ns} gpus=${gpus} scheduler=${SCHEDULER}"
  cat <<EOF | kapply
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: swebench-live-vllm
    app: swebench-instance
    squad: ${squad}
    split: ${split}
    scenario: "${SCENARIO_ID}"
    scheduler: ${SCHEDULER}
    gpu-shape: profiled
${kueue_labels}
  annotations:
${anno_lines}
spec:
${suspend_line}
  backoffLimit: 0
  completions: 1
  parallelism: 1
  ttlSecondsAfterFinished: 1800
  activeDeadlineSeconds: ${deadline}
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: swebench-live-vllm
        app: swebench-instance
        squad: ${squad}
        split: ${split}
        scenario: "${SCENARIO_ID}"
        gpu-shape: profiled
${tmpl_runai_label}
    spec:
${sched_line}
      restartPolicy: Never
      priorityClassName: ${prio}
      terminationGracePeriodSeconds: 10
      tolerations:
        - key: ${GPU_TAINT_KEY}
          operator: Exists
          effect: NoSchedule
      containers:
        - name: gpu-hold
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "scenario=${SCENARIO_ID} squad=${squad} profiled=${HARDWARE_PROFILE}"
              echo "holding ${gpus}x${GPU_RESOURCE} for ${hold}s on \$(hostname)"
              sleep ${hold}
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
              ${GPU_RESOURCE}: "${gpus}"
            limits:
              cpu: "4"
              memory: 8Gi
              ${GPU_RESOURCE}: "${gpus}"
EOF
}

parse_common_args "$@"
require_server
init_report

if [[ "$DO_CLEANUP" == 1 ]]; then cleanup_scenario; exit 0; fi
check_namespaces

section "Plan"
note "Heterogeneous GPU demand competing for flavor \`${ACCELERATOR_FLAVOR}\`:"
note "- Squad A: 1 × **2-GPU** profiled job (tensor-parallel vLLM shape, profile \`${HARDWARE_PROFILE}\`)"
note "- Squad B: 2 × **1-GPU** jobs, no profile (inference replicas)"
note "- Squad C: 1 × **1-GPU** job, no profile"
note "Total demand = 5 GPUs on the ${POOL_GPU_TOTAL}-GPU pool, so all fit — the focus is how the scheduler PACKS mixed shapes and honours the profile."

section "Submit (heterogeneous shapes)"
emit_profiled_job "a" "vllm-tp2" 2 "$HOLD"
submit_gpu_job   "b" "replica-1" 1 "$HOLD"
submit_gpu_job   "b" "replica-2" 1 "$HOLD"
submit_gpu_job   "c" "single"    1 "$HOLD"

settle 30

section "Admission & placement"
show_admission

section "Placement detail (which node each GPU pod landed on)"
for s in "${SQUADS[@]}"; do
  capture "Pods on nodes in ${SQUAD_NS[$s]}" \
    oc get pods -n "${SQUAD_NS[$s]}" -l scenario="${SCENARIO_ID}" \
      -o custom-columns=POD:.metadata.name,SHAPE:.metadata.labels.gpu-shape,NODE:.spec.nodeName,PHASE:.status.phase
done

section "Per-squad workloads & GPU accounting"
show_workloads

section "What to watch / what this proves"
note "- **Profile vs no-profile:** the profiled 2-GPU job is admitted against the \`${HARDWARE_PROFILE}\` hardware profile / \`${ACCELERATOR_FLAVOR}\` flavor; the no-profile jobs share the same flavor without a profile. Confirm all resolve to the same GPU node pool."
note "- **Packing:** check the NODE column — single-GPU replicas may co-locate on one node while the 2-GPU job needs two free GPUs on a node, exposing fragmentation."
note "- **rhoai:** Kueue admits each as a Workload against its ClusterQueue; \`oc get workloads -A -o wide\` shows the flavor assignment."
note "- **runai:** the Run:AI scheduler bin-packs GPU fractions/whole GPUs; with GPU fractioning enabled, sub-GPU sharing would show here."
note "- **Proves:** the pool serves heterogeneous GPU shapes (TP inference, single-GPU replicas, profiled and unprofiled) from one shared flavor without manual node pinning."

finish_report
