#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import logging
import os
import re

from oslo_config import cfg
from oslo_messaging.notify import notifier
from prometheus_client import CollectorRegistry
from prometheus_client import write_to_textfile

from ironic_prometheus_exporter.parsers import header
from ironic_prometheus_exporter.parsers import ipmi
from ironic_prometheus_exporter.parsers import ironic as ironic_parser
from ironic_prometheus_exporter.parsers import redfish


LOG = logging.getLogger(__name__)


# Event type emitted by ironic for conductor-level metrics. See
# ConductorManager._sensors_conductor() in ironic.
CONDUCTOR_EVENT_TYPE = 'ironic.metrics'

# Event type emitted by ironic for node sensor data. Ironic builds this as
# 'hardware.{node.driver}.metrics', so the middle segment is the node's
# hardware type and can be any value registered in the deployment (ipmi,
# redfish, idrac, ilo, irmc, snmp, or a third party hardware type). See
# ConductorManager._sensors_nodes_task() in ironic.
NODE_EVENT_TYPE_RE = re.compile(r'^hardware\..+\.metrics$')


def is_metrics_notification(event_type):
    """Return True if the notification carries metrics we should export.

    The driver is registered as an oslo.messaging notification driver and
    therefore receives every notification ironic emits, including versioned
    notifications such as NodeSetPowerStatePayload. Those carry a versioned
    object payload that this exporter cannot parse and must not attempt to
    write out.
    """
    if not event_type:
        return False
    return (event_type == CONDUCTOR_EVENT_TYPE
            or bool(NODE_EVENT_TYPE_RE.match(event_type)))


prometheus_opts = [
    cfg.StrOpt('location', required=True,
               help='Directory where the files will be written.')
]


def register_opts(conf):
    conf.register_opts(prometheus_opts, group='oslo_messaging_notifications')


class PrometheusFileDriver(notifier.Driver):
    """Publish notifications into a File to be used by Prometheus"""

    # Node metrics event types that have a dedicated sensor parser. Node
    # notifications for any other hardware type still produce the header
    # timestamp metric so operators can tell the node is reporting.
    NODE_PARSERS = {
        'hardware.ipmi.metrics': ipmi.category_registry,
        'hardware.redfish.metrics': redfish.category_registry,
        'hardware.idrac.metrics': redfish.category_registry,
    }

    def __init__(self, conf, topics, transport):
        self.location = conf.oslo_messaging_notifications.location
        if not os.path.exists(self.location):
            os.makedirs(self.location)
        super(PrometheusFileDriver, self).__init__(conf, topics, transport)

    def notify(self, ctxt, message, priority, retry):
        event_type = message.get('event_type')
        if not is_metrics_notification(event_type):
            # Not a metrics notification, ignore it instead of trying to
            # parse a payload we do not understand.
            LOG.debug("Ignoring non-metrics notification event_type: %s",
                      event_type)
            return

        try:
            registry = CollectorRegistry()
            payload = message['payload']
            if event_type == CONDUCTOR_EVENT_TYPE:
                # We know this message payload is from a conductor itself
                # and not for node drivers.
                header.timestamp_conductor_registry(payload, registry)
                ironic_parser.category_registry(payload, registry)

            else:
                header.timestamp_registry(payload, registry)
                parser = self.NODE_PARSERS.get(event_type)
                if parser is not None:
                    parser(payload, registry)
                else:
                    LOG.debug("No sensor parser for event_type %s, only the "
                              "timestamp metric will be exported.", event_type)

            # Order of preference is for a node Name, UUID, or
            # payload hostname field to be used (i.e. for conductor
            # message payloads).
            field = (
                payload.get('node_name') or
                payload.get('node_uuid') or
                payload.get('hostname')
            )
            if not field:
                # Without an identifier we cannot build a stable filename,
                # so skip writing rather than crashing.
                LOG.warning(
                    "Skipping notification '%s': payload is missing a "
                    "node_name, node_uuid, and hostname identifier.",
                    event_type)
                return

            statFile = os.path.join(
                self.location, field + '-' + event_type)

            # Writes to file for server pickup
            write_to_textfile(statFile, registry)

        except Exception as e:
            LOG.error(e)
            raise


class SimpleFileDriver(notifier.Driver):

    def __init__(self, conf, topics, transport):
        self.location = conf.oslo_messaging_notifications.location
        if not os.path.exists(self.location):
            os.makedirs(os.path.dirname(self.location))
        super(SimpleFileDriver, self).__init__(conf, topics, transport)

    def notify(self, ctx, message, priority, retry):
        with open(os.path.join(self.location, 'simplefile'), 'w') as file:
            file.write(message)
