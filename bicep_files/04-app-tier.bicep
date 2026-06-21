// ============================================================
// 04-app-tier.bicep
// Deploys:
//   - App LB VM  (nginx reverse proxy, 10.0.4.4,   Zone 1, lb-subnet)
//   - App VM 1-4 (Node.js :8080,       10.0.2.10-13)
//   - Postgres Primary               (10.0.3.4,   Zone 1)
//   - Postgres Secondary             (10.0.3.5,   Zone 2)
// Target RG: rg-jxd-ddd
// ============================================================

@description('Admin username for all VMs')
param adminUsername string = 'azureadmin'

@description('Admin password for all VMs')
@secure()
param adminPassword string

@description('Prefix for all resource names')
param prefix string = 'flowdemo'

@description('Azure region')
param location string = resourceGroup().location

// ── Reference existing VNet / subnets ───────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' existing = {
  name: '${prefix}-vnet'
}

resource lbSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'lb-subnet'
}

resource appSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'app-subnet'
}

resource dbSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' existing = {
  parent: vnet
  name: 'db-subnet'
}

// ── VM size (only size available in this sub/region) ────────
var vmSize = 'Standard_D2s_v6'

// ── Shared cloud-init scripts ────────────────────────────────

// nginx acting as L7 round-robin proxy to app VMs :8080
// Write directly to conf.d/ — no symlink required, nginx includes this
// directory automatically. Added nginx -t to runcmd so config errors
// surface in cloud-init logs rather than silently failing.
var nginxCloudInit = '''
#cloud-config
package_update: true
packages:
  - nginx
write_files:
  - path: /etc/nginx/conf.d/appproxy.conf
    content: |
      upstream appvms {
          server 10.0.2.10:8080;
          server 10.0.2.11:8080;
          server 10.0.2.12:8080;
          server 10.0.2.13:8080;
      }
      server {
          listen 80;
          location / {
              proxy_pass http://appvms;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          }
          location /health {
              return 200 'app-lb-ok';
              add_header Content-Type text/plain;
          }
      }
runcmd:
  - rm -f /etc/nginx/sites-enabled/default
  - nginx -t
  - systemctl enable nginx
  - systemctl restart nginx
'''

// Node.js REST API on :8080
var nodeCloudInit = '''
#cloud-config
package_update: true
packages:
  - snapd
write_files:
  - path: /opt/api/server.js
    content: |
      const http = require('http');
      const os   = require('os');
      const { Pool } = require('pg');
      const port = 8080;

      const pool = new Pool({
        host:     '10.0.3.4',
        port:     5432,
        database: 'appdb',
        user:     'postgres',
        password: 'PgPass123!',
        max: 5,
        idleTimeoutMillis: 30000,
        connectionTimeoutMillis: 3000,
      });

      // Ensure requests table exists on startup (retry until Postgres is ready)
      async function ensureSchema() {
        for (let i = 0; i < 10; i++) {
          try {
            await pool.query(`
              CREATE TABLE IF NOT EXISTS requests (
                id          SERIAL PRIMARY KEY,
                ts          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                app_host    TEXT,
                method      TEXT,
                path        TEXT,
                remote_addr TEXT,
                user_agent  TEXT,
                job_ms      INT,
                duration_ms INT
              )
            `);
            console.log('Schema ready');
            return;
          } catch (e) {
            console.log('Waiting for Postgres... ' + e.message);
            await new Promise(r => setTimeout(r, 5000));
          }
        }
      }
      ensureSchema();

      http.createServer(async (req, res) => {
        const start = Date.now();
        const host  = os.hostname();

        if (req.url === '/health') {
          res.writeHead(200, {'Content-Type': 'application/json'});
          res.end(JSON.stringify({status:'ok', host}));
          return;
        }

        // Simulate long-running job: random delay 1000-2000ms
        const jobMs = Math.floor(Math.random() * 1000) + 1000;
        await new Promise(r => setTimeout(r, jobMs));

        // Insert request record
        let dbResult = null;
        let dbError  = null;
        try {
          const r = await pool.query(
            `INSERT INTO requests (app_host, method, path, remote_addr, user_agent, job_ms, duration_ms)
             VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING id, ts`,
            [
              host,
              req.method,
              req.url,
              req.socket.remoteAddress,
              req.headers['user-agent'] || '',
              jobMs,
              Date.now() - start
            ]
          );
          dbResult = r.rows[0];
        } catch (e) {
          dbError = e.message;
        }

        // Also fetch last 3 requests to show in response
        let recentRequests = [];
        try {
          const r = await pool.query(
            `SELECT id, ts, app_host, path, job_ms, duration_ms FROM requests ORDER BY id DESC LIMIT 3`
          );
          recentRequests = r.rows;
        } catch (e) {}

        res.writeHead(200, {'Content-Type': 'application/json'});
        res.end(JSON.stringify({
          message:         'Hello from Node.js API',
          host,
          timestamp:       new Date().toISOString(),
          job_ms:          jobMs,
          total_ms:        Date.now() - start,
          request_id:      dbResult ? dbResult.id  : null,
          request_ts:      dbResult ? dbResult.ts   : null,
          db_error:        dbError,
          recent_requests: recentRequests
        }, null, 2));
      }).listen(port, () => console.log('API listening on ' + port));
  - path: /etc/systemd/system/nodeapi.service
    content: |
      [Unit]
      Description=Node.js REST API
      After=network.target
      [Service]
      ExecStart=/snap/bin/node /opt/api/server.js
      Restart=always
      User=root
      Environment=HOME=/root
      Environment=NODE_ENV=production
      [Install]
      WantedBy=multi-user.target
runcmd:
  - mkdir -p /opt/api
  - snap install node --classic --channel=18
  - ln -sf /snap/bin/node /usr/bin/node
  - ln -sf /snap/bin/npm /usr/bin/npm
  - cd /opt/api && /snap/bin/npm init -y && /snap/bin/npm install pg
  - systemctl daemon-reload
  - systemctl enable nodeapi
  - systemctl start nodeapi
'''

// Postgres primary — installs, initialises DB, enables replication slot
var pgPrimaryCloudInit = '''
#cloud-config
package_update: true
packages:
  - postgresql
  - postgresql-contrib
runcmd:
  - systemctl enable postgresql
  - systemctl start postgresql
  - sudo -u postgres psql -c "ALTER USER postgres PASSWORD 'PgPass123!';"
  - sudo -u postgres psql -c "CREATE DATABASE appdb;"
  - sudo -u postgres psql -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'ReplPass123!';"
  - PG_VERSION=$(ls /etc/postgresql/) && echo "host replication replicator 10.0.3.0/24 md5" >> /etc/postgresql/${PG_VERSION}/main/pg_hba.conf
  - PG_VERSION=$(ls /etc/postgresql/) && echo "host appdb postgres 10.0.2.0/24 md5" >> /etc/postgresql/${PG_VERSION}/main/pg_hba.conf
  - PG_VERSION=$(ls /etc/postgresql/) && sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/${PG_VERSION}/main/postgresql.conf
  - PG_VERSION=$(ls /etc/postgresql/) && sed -i "s/#wal_level = replica/wal_level = replica/" /etc/postgresql/${PG_VERSION}/main/postgresql.conf
  - PG_VERSION=$(ls /etc/postgresql/) && sed -i "s/#max_wal_senders = 10/max_wal_senders = 5/" /etc/postgresql/${PG_VERSION}/main/postgresql.conf
  - PG_VERSION=$(ls /etc/postgresql/) && sed -i "s/#wal_keep_size = 0/wal_keep_size = 64/" /etc/postgresql/${PG_VERSION}/main/postgresql.conf
  - systemctl restart postgresql
'''

// Postgres secondary — streams from primary
var pgSecondaryCloudInit = '''
#cloud-config
package_update: true
packages:
  - postgresql
  - postgresql-contrib
runcmd:
  - systemctl stop postgresql
  - rm -rf /var/lib/postgresql/*/main
  - sudo -u postgres pg_basebackup -h 10.0.3.4 -D /var/lib/postgresql/$(ls /etc/postgresql)/main -U replicator -P -Xs -R
  - echo "primary_conninfo = 'host=10.0.3.4 port=5432 user=replicator password=ReplPass123!'" >> /var/lib/postgresql/$(ls /etc/postgresql)/main/postgresql.auto.conf
  - touch /var/lib/postgresql/$(ls /etc/postgresql)/main/standby.signal
  - chown -R postgres:postgres /var/lib/postgresql
  - systemctl start postgresql
'''

// ── Helper: base64-encode cloud-init for customData ─────────
// Bicep doesn't have a built-in base64() over multiline literals,
// so we pass the raw string and ARM handles UTF-8 → base64 via
// the base64() function at deploy time.

// ============================================================
// APP LB VM  —  10.0.4.4 / Zone 1 / lb-subnet
// ============================================================
resource appLbNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-applb-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.0.4.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: lbSubnet.id
          }
        }
      }
    ]
  }
}

resource appLbVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${prefix}-applb'
  location: location
  zones: ['1']
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    osProfile: {
      computerName: '${prefix}-applb'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(nginxCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: appLbNic.id }]
    }
  }
}

// ============================================================
// APP VMs  —  10.0.2.10-13  (no explicit zone — spread by platform)
// ============================================================
var appVmCount = 4
var appVmBaseOctet = 10   // .10, .11, .12, .13

resource appNics 'Microsoft.Network/networkInterfaces@2023-09-01' = [for i in range(0, appVmCount): {
  name: '${prefix}-app${i + 1}-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.0.2.${appVmBaseOctet + i}'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: appSubnet.id
          }
        }
      }
    ]
  }
}]

resource appVms 'Microsoft.Compute/virtualMachines@2023-09-01' = [for i in range(0, appVmCount): {
  name: '${prefix}-app${i + 1}'
  location: location
  dependsOn: [appNics]
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
    }
    osProfile: {
      computerName: '${prefix}-app${i + 1}'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(nodeCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: appNics[i].id }]
    }
  }
}]

// ============================================================
// POSTGRES PRIMARY  —  10.0.3.4 / Zone 1
// ============================================================
resource pgPrimaryNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-pgprimary-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.0.3.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: dbSubnet.id
          }
        }
      }
    ]
  }
}

resource pgPrimaryVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${prefix}-pgprimary'
  location: location
  zones: ['1']
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          name: '${prefix}-pgprimary-datadisk'
          createOption: 'Empty'
          diskSizeGB: 64
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      ]
    }
    osProfile: {
      computerName: '${prefix}-pgprimary'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(pgPrimaryCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: pgPrimaryNic.id }]
    }
  }
}

// ============================================================
// POSTGRES SECONDARY  —  10.0.3.5 / Zone 2
// (depends on primary being up — pg_basebackup runs at boot)
// ============================================================
resource pgSecondaryNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${prefix}-pgsecondary-nic'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAddress: '10.0.3.5'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: dbSubnet.id
          }
        }
      }
    ]
  }
}

resource pgSecondaryVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${prefix}-pgsecondary'
  location: location
  zones: ['2']
  dependsOn: [pgPrimaryVm]   // primary must be provisioned first
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Premium_LRS' }
      }
      dataDisks: [
        {
          lun: 0
          name: '${prefix}-pgsecondary-datadisk'
          createOption: 'Empty'
          diskSizeGB: 64
          managedDisk: { storageAccountType: 'Premium_LRS' }
        }
      ]
    }
    osProfile: {
      computerName: '${prefix}-pgsecondary'
      adminUsername: adminUsername
      adminPassword: adminPassword
      customData: base64(pgSecondaryCloudInit)
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [{ id: pgSecondaryNic.id }]
    }
  }
}

// ============================================================
// OUTPUTS
// ============================================================
output appLbPrivateIp string = appLbNic.properties.ipConfigurations[0].properties.privateIPAddress  // 10.0.4.4 (lb-subnet)
output pgPrimaryPrivateIp string = pgPrimaryNic.properties.ipConfigurations[0].properties.privateIPAddress
output pgSecondaryPrivateIp string = pgSecondaryNic.properties.ipConfigurations[0].properties.privateIPAddress
