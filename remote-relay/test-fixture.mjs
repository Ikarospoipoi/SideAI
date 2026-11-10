// Local integration test only. Never writes pairing credentials.
import fs from 'node:fs';
import {createRelay} from './server.mjs';
const relay=createRelay();
relay.server.listen(0,'127.0.0.1',()=>fs.writeFileSync(process.argv[2],String(relay.server.address().port)));
process.on('SIGTERM',()=>relay.close().then(()=>process.exit(0)));
