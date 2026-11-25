import lazy { socket } from '@kit.NetworkKit';
import lazy { cert } from '@kit.DeviceCertificateKit';

const API_HOST: string = 'api.github.com';
const MAX_HEADER_BYTES: number = 32 * 1024;

export interface PatchReply {
  status: number;
  headers: Record<string, string>;
}

function dnsName(name: string): cert.GeneralName {
  // DER encoding for a context-specific dNSName [2], with ASCII DNS bytes.
  const der = new Uint8Array(name.length + 2);
  der[0] = 0x82;
  der[1] = name.length;
  for (let i = 0; i < name.length; i++) {
    der[i + 2] = name.charCodeAt(i);
  }
  return { type: cert.GeneralNameType.GENERAL_NAME_TYPE_DNS_NAME, name: der };
}

function parseHeaders(block: string): PatchReply {
  const lines = block.split('\r\n');
  const match = /^HTTP\/1\.[01] ([1-5][0-9]{2})(?: |$)/.exec(lines[0]);
  if (!match) {
    throw new Error('GitHub 响应格式无效');
  }
  const headers: Record<string, string> = {};
  for (let i = 1; i < lines.length; i++) {
    const separator = lines[i].indexOf(':');
    if (separator < 1) {
      continue;
    }
    const name = lines[i].slice(0, separator).toLowerCase();
    if (name === 'retry-after' || name === 'x-ratelimit-remaining' || name === 'x-ratelimit-reset') {
      headers[name] = lines[i].slice(separator + 1).trim();
    }
  }
  return { status: Number(match[1]), headers: headers };
}

async function closeSocket(client: socket.TLSSocket): Promise<void> {
  try {
    await client.close();
  } catch (_) {
    // A bind/handshake may fail before there is a usable socket to close.
  }
}

async function sendPatch(client: socket.TLSSocket, path: string, token: string, agent: string,
  active: () => boolean, beforeSend: () => void): Promise<void> {
  await client.bind({ address: '0.0.0.0', family: 1, port: 0 });
  if (!active()) {
    await closeSocket(client);
    return;
  }
  await client.connect({
    address: { address: API_HOST, family: 1, port: 443 },
    secureOptions: { isBidirectionalAuthentication: false },
    skipRemoteValidation: false,
    ALPNProtocols: ['http/1.1']
  });
  if (!active()) {
    await closeSocket(client);
    return;
  }
  const peer = await cert.createX509Cert(await client.getRemoteCertificate());
  // System TLS checks the CA chain. Check the hostname independently because
  // some platform TLS socket versions do not enforce a SAN mismatch themselves.
  const match: cert.X509CertMatchParameters = {
    subjectAlternativeNames: [dnsName(API_HOST), dnsName('*.github.com')],
    matchAllSubjectAltNames: false
  };
  if (!peer.match(match)) {
    throw new Error('GitHub TLS 身份验证失败');
  }
  if (!active()) {
    await closeSocket(client);
    return;
  }
  // Only a single request is sent over this connection. No redirects are followed.
  beforeSend();
  await client.send(`PATCH ${path} HTTP/1.1\r\nHost: ${API_HOST}\r\nUser-Agent: ${agent}\r\n` +
    'Accept: application/vnd.github+json\r\nX-GitHub-Api-Version: 2022-11-28\r\n' +
    `Authorization: Bearer ${token}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
}

// API 18/20 NetworkKit HTTP does not offer PATCH. This narrowly handles GitHub's
// single-thread mark, whose result is status-only; the socket is never reused.
export function patchThread(path: string, token: string, agent: string, timeout: number): Promise<PatchReply> {
  return new Promise<PatchReply>((resolve: (reply: PatchReply) => void, reject: (error: Error) => void) => {
    if (!/^\/notifications\/threads\/[1-9][0-9]{0,19}$/.test(path) || !/^[A-Za-z0-9_]{1,512}$/.test(token) ||
      !/^[!-~]+$/.test(agent)) {
      reject(new Error('GitHub 通知请求无效'));
      return;
    }
    const client: socket.TLSSocket = socket.constructTLSSocketInstance();
    let finished = false;
    let readyToReceive = false;
    let header = '';
    let bytes = 0;
    let timer = 0;
    const cleanup = (): void => {
      finished = true;
      clearTimeout(timer);
      closeSocket(client);
    };
    const fail = (): void => {
      if (!finished) {
        cleanup();
        reject(new Error('无法确认 GitHub 已标记通知，请刷新后查看'));
      }
    };
    timer = setTimeout(fail, timeout);
    try {
      client.on('error', () => fail());
      client.on('close', () => fail());
      client.on('message', (data: socket.SocketMessageInfo) => {
        if (finished || !readyToReceive) {
          return;
        }
        try {
          for (const byte of new Uint8Array(data.message)) {
            bytes++;
            if (bytes > MAX_HEADER_BYTES) {
              fail();
              return;
            }
            header += String.fromCharCode(byte);
            if (byte !== 10 || !header.endsWith('\r\n\r\n')) {
              continue;
            }
            const reply = parseHeaders(header.slice(0, -4));
            if (reply.status < 200 && reply.status !== 101) {
              header = '';
              continue;
            }
            cleanup();
            resolve(reply);
            return;
          }
        } catch (_) {
          fail();
        }
      });
      sendPatch(client, path, token, agent, () => !finished, () => { readyToReceive = true; }).catch(() => fail());
    } catch (_) {
      fail();
    }
  });
}
