#!/bin/bash
# Seed the _default configset into SOLR_HOME/configsets.
#
# The backend creates cores at boot via CoreAdmin CREATE with configSet=_default
# (SolrConfig.createCollectionIfNotExists). Solr resolves that name under
# SOLR_HOME/configsets (/var/solr/data/configsets), but the solr:9 image only
# ships _default under the install dir (/opt/solr/server/solr/configsets), so the
# search path is empty and every core create fails with
# "Could not load configuration from directory .../configsets/_default".
#
# run-initdb runs this before Solr starts, so the template is in place before the
# app connects. Idempotent: the solr_data volume persists it across restarts.
if [ ! -d /var/solr/data/configsets/_default ]; then
  mkdir -p /var/solr/data/configsets
  cp -r /opt/solr/server/solr/configsets/_default /var/solr/data/configsets/_default
  echo "[configset-init] seeded _default configset into SOLR_HOME/configsets"
else
  echo "[configset-init] _default configset already present"
fi
