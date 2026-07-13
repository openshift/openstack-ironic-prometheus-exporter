#!/usr/bin/env bash
# plugin.sh - DevStack plugin.sh dispatch script template

IRONIC_PROMETHEUS_EXPORTER_DIR=${IRONIC_PROMETHEUS_EXPORTER_DIR:-$DEST/ironic-prometheus-exporter}
IRONIC_PROMETHEUS_EXPORTER_PORT=${IRONIC_PROMETHEUS_EXPORTER_PORT:-9608}
IRONIC_PROMETHEUS_EXPORTER_DATA_DIR=""$DATA_DIR/ironic-prometheus-exporter""
IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE="devstack@ironic-prometheus-exporter.service"
# Location where the metrics from the baremetal nodes will be stored
IRONIC_PROMETHEUS_EXPORTER_LOCATION=${IRONIC_PROMETHEUS_EXPORTER_LOCATION:-$IRONIC_VM_LOG_DIR}
COLLECT_DATA_UNDEPLOYED_NODES=$(trueorfalse True COLLECT_DATA_UNDEPLOYED_NODES)
IRONIC_CONFIG=${IRONIC_CONFIG:-$IRONIC_CONF_FILE}
IPE_ACCESS_LF="$IRONIC_VM_LOG_DIR/ipe_access.log"
IPE_ERROR_LF="$IRONIC_VM_LOG_DIR/ipe_errors.log"

function install_ironic_prometheus_exporter {
    git_clone_by_name "ironic-prometheus-exporter"
    # NOTE(TheJulia): Version and use requirement is not established
    # for gunicorn. It just so happens to be what the CI job uses,
    # and is not an operational requirement.
    pip_install gunicorn
    setup_dev_lib "ironic-prometheus-exporter"
}

function configure_ironic_prometheus_exporter {
    # Update ironic configuration file to use the exporter
    iniset $IRONIC_CONF_FILE sensor_data send_sensor_data true
    iniset $IRONIC_CONF_FILE sensor_data enable_for_undeployed_nodes $COLLECT_DATA_UNDEPLOYED_NODES
    iniset $IRONIC_CONF_FILE sensor_data interval 90
    iniset $IRONIC_CONF_FILE metrics backend collector
    iniset $IRONIC_CONF_FILE oslo_messaging_notifications driver prometheus_exporter
    iniset $IRONIC_CONF_FILE oslo_messaging_notifications transport_url fake://
    iniset $IRONIC_CONF_FILE oslo_messaging_notifications location $IRONIC_PROMETHEUS_EXPORTER_LOCATION

    mkdir -p "$IRONIC_PROMETHEUS_EXPORTER_LOCATION"

    local gunicorn_ipe_cmd

    gunicorn_ipe_cmd=$(which gunicorn)
    gunicorn_ipe_cmd+=" -b ${SERVICE_HOST}:${IRONIC_PROMETHEUS_EXPORTER_PORT}"
    gunicorn_ipe_cmd+=" --env IRONIC_CONFIG=$IRONIC_CONFIG"
    gunicorn_ipe_cmd+=" --env FLASK_DEBUG=1 -w 4"
    gunicorn_ipe_cmd+=" --access-logfile=$IPE_ACCESS_LF --error-logfile=$IPE_ERROR_LF"
    gunicorn_ipe_cmd+=" -D ironic_prometheus_exporter.app.wsgi:application"

    write_user_unit_file $IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE "$gunicorn_ipe_cmd" "" "$STACK_USER"

    enable_service $IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE
}

function start_ironic_prometheus_exporter {
    start_service $IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE
}

function stop_ironic_prometheus_exporter {
    stop_service $IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE
}

function cleanup_ironic_prometheus_exporter {
    stop_ironic_prometheus_exporter

    disable_service $IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE

    sudo rm -rf $IRONIC_PROMETHEUS_EXPORTER_DATA_DIR

    local unitfile="$SYSTEMD_DIR/$IRONIC_PROMETHEUS_EXPORTER_SYSTEMD_SERVICE"
    sudo rm -f $unitfile

    $SYSTEMCTL daemon-reload
}

function log_sensor_data_diagnostics {
    local node_file="node-0-hardware.redfish.metrics"
    local stats_file
    stats_file="$(hostname)-ironic.metrics"

    echo "=== IPE sensor data diagnostics ==="
    echo "IRONIC_PROMETHEUS_EXPORTER_LOCATION=${IRONIC_PROMETHEUS_EXPORTER_LOCATION}"
    echo "IRONIC_CONF_FILE=${IRONIC_CONF_FILE}"

    if [[ -f "$IRONIC_CONF_FILE" ]]; then
        echo "[sensor_data] from ironic.conf:"
        awk '/^\[sensor_data\]/,/^\[/ {print}' "$IRONIC_CONF_FILE" | head -10
        echo "[oslo_messaging_notifications] from ironic.conf:"
        awk '/^\[oslo_messaging_notifications\]/,/^\[/ {print}' "$IRONIC_CONF_FILE" | head -10
    fi

    if pgrep -af ironic-conductor >/dev/null 2>&1; then
        echo "ironic-conductor processes:"
        pgrep -af ironic-conductor || true
    else
        echo "WARNING: no ironic-conductor process found"
    fi

    if [[ -d "$IRONIC_PROMETHEUS_EXPORTER_LOCATION" ]]; then
        echo "Contents of ${IRONIC_PROMETHEUS_EXPORTER_LOCATION}:"
        ls -la "$IRONIC_PROMETHEUS_EXPORTER_LOCATION" 2>/dev/null || true
    else
        echo "Directory ${IRONIC_PROMETHEUS_EXPORTER_LOCATION} does not exist"
    fi

    for f in "$node_file" "$stats_file"; do
        if [[ -f "$IRONIC_PROMETHEUS_EXPORTER_LOCATION/$f" ]]; then
            echo "Found metrics file: $f"
        else
            echo "Missing metrics file: $f"
        fi
    done

    if [[ -f "$IPE_ERROR_LF" ]]; then
        echo "Last lines of ${IPE_ERROR_LF}:"
        tail -20 "$IPE_ERROR_LF" 2>/dev/null || true
    fi

    echo "=== end diagnostics ==="
}

function wait_for_data {
    # Wait for sensor data to be collected and written by the exporter.
    # After a conductor restart, allow time for the periodic scheduler
    # (sensor_data.interval, default 90s) plus collection latency.
    local node_file="node-0-hardware.redfish.metrics"
    local stats_file
    stats_file="$(hostname)-ironic.metrics"
    local max_attempts=120
    local wait_interval=10
    local attempt=0

    echo "Waiting for $node_file (checking every ${wait_interval}s for up to $((max_attempts * wait_interval))s)..."

    while [ $attempt -lt $max_attempts ]; do
        if [ -f "$IRONIC_PROMETHEUS_EXPORTER_LOCATION/$node_file" ]; then
            echo "Found $node_file after $((attempt * wait_interval)) seconds"
            return 0
        fi

        if [ -f "$IRONIC_PROMETHEUS_EXPORTER_LOCATION/$stats_file" ]; then
            echo "Found conductor metrics $stats_file (still waiting for $node_file)"
        fi

        attempt=$((attempt + 1))
        if [ $((attempt % 6)) -eq 0 ]; then
            echo "Still waiting (${attempt}/${max_attempts})..."
            if [ -d "$IRONIC_PROMETHEUS_EXPORTER_LOCATION" ]; then
                ls -la "$IRONIC_PROMETHEUS_EXPORTER_LOCATION" 2>/dev/null || true
            fi
        fi
        sleep $wait_interval
    done

    echo "WARNING: $node_file not found after $((max_attempts * wait_interval)) seconds"
    log_sensor_data_diagnostics
    return 1
}

function check_data {
    local node_file="node-0-hardware.redfish.metrics"
    if [ ! -f "$IRONIC_PROMETHEUS_EXPORTER_LOCATION/$node_file" ]; then
        die $LINENO "Couldn't find $node_file in $IRONIC_PROMETHEUS_EXPORTER_LOCATION"
    fi
    echo "Found $node_file in $IRONIC_PROMETHEUS_EXPORTER_LOCATION"

    local stats_file
    stats_file="$(hostname)-ironic.metrics"
    if [ ! -f "$IRONIC_PROMETHEUS_EXPORTER_LOCATION/$stats_file" ]; then
        die $LINENO "Could not find $stats_file in $IRONIC_PROMETHEUS_EXPORTER_LOCATION"
    fi

    local url="http://$SERVICE_HOST:$IRONIC_PROMETHEUS_EXPORTER_PORT/metrics"
    local attempt=0
    local max_attempts=12

    echo "Waiting for exporter to become ready at $url ..."
    while [ $attempt -lt $max_attempts ]; do
        if curl -s --head --request GET "$url" | grep "200 OK" > /dev/null; then
            echo "Data successfully retrieved from ironic-prometheus-exporter application"
            echo "#### Metrics data ####"
            curl "$url"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 5
    done

    die $LINENO "Couldn't get data from ironic-prometheus-exporter application after $((max_attempts * 5))s"
}

echo_summary "ironic-prometheus-exporter devstack plugin.sh called: $1/$2"

if is_service_enabled ironic-prometheus-exporter; then

    if [[ "$1" == "stack" ]]; then
        case "$2" in
            install)
                echo_summary "Installing Ironic Prometheus Exporter"
                install_ironic_prometheus_exporter
                ;;
            post-config)
                echo_summary "Configuring Ironic Prometheus Exporter Application"
                configure_ironic_prometheus_exporter
                ;;
            extra)
                echo_summary "Starting Ironic Prometheus Exporter Application"
                start_ironic_prometheus_exporter
                echo_summary "Give time to baremetal to provide data"
                wait_for_data
                check_data
                ;;
        esac
    fi

    if [[ "$1" == "unstack" ]]; then
        echo_summary "Stopping Ironic Prometheus Exporter Application"
        stop_ironic_prometheus_exporter
        echo_summary "Cleaning Ironic Prometheus Exporter"
        cleanup_ironic_prometheus_exporter
    fi

fi
