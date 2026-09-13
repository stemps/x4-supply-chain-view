"""Nexus Mods v3 publisher with durable checkpoints around non-repeatable writes.

Contract: https://api-docs.nexusmods.com/ (checked September 2026).
Uses only the Python standard library. No HTTP bodies, keys or signed URLs are logged.
"""
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
from decimal import Decimal
from email.utils import parsedate_to_datetime
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree as ET

from release_archive import ReleaseError

BASE = 'https://api.nexusmods.com'
SINGLE_LIMIT = 100 * 1024 * 1024
DOWNLOAD_OPTIONS = ('primary_mod_manager_download', 'allow_mod_manager_download', 'show_requirements_pop_up')


class ApiError(ReleaseError):
    def __init__(self, message, uncertain=False):
        super().__init__(message)
        self.uncertain = uncertain


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, key=None, opener=None, sleep=time.sleep):
        self.key = key if key is not None else os.environ.get('X4_NEXUS_KEY', '')
        if not self.key:
            raise ReleaseError('Set X4_NEXUS_KEY to your Nexus personal API key.')
        self.opener = opener or urllib.request.build_opener(NoRedirect())
        self.sleep = sleep

    def request(self, method, path, body=None, *, raw=None, headers=None, storage=False):
        url = path if storage else BASE + path
        if urllib.parse.urlsplit(url).scheme != 'https':
            raise ReleaseError('Nexus upload URLs must use HTTPS.')
        request_headers = dict(headers or {})
        if not storage:
            request_headers.update({'apikey': self.key, 'User-Agent': 'Supply-Chain-View-release/1.0',
                                    'Content-Type': 'application/json'})
        data = json.dumps(body).encode() if body is not None else raw
        label = 'Storage transfer' if storage else f'Nexus {method} {path.split("?")[0]}'
        for attempt in range(4):
            try:
                request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
                with self.opener.open(request, timeout=45) as response:
                    payload = response.read()
                    if storage:
                        # Multipart completion can return an XML Error with HTTP 200.
                        if method == 'POST' and payload and ET.fromstring(payload).tag.split('}')[-1] == 'Error':
                            raise ApiError('Storage multipart completion failed.', uncertain=True)
                        return dict(response.headers), payload
                    result = json.loads(payload) if payload else {}
                    return result.get('data', result) if isinstance(result, dict) else result
            except urllib.error.HTTPError as error:
                uncertain = error.code >= 500 or error.code == 408
                retry = error.code == 429 or (method in ('GET', 'PUT') and uncertain)
                delay = 2 ** attempt
                retry_after = error.headers.get('Retry-After') if error.headers else None
                if retry_after:
                    try:
                        delay = max(0, float(retry_after))
                    except ValueError:
                        try:
                            delay = max(0, (parsedate_to_datetime(retry_after) - datetime.now(timezone.utc)).total_seconds())
                        except (ValueError, TypeError):
                            pass
                if retry and attempt < 3 and delay <= 60:
                    self.sleep(delay)
                    continue
                raise ApiError(f'{label} failed (HTTP {error.code}); retry later.' if retry else
                               f'{label} failed (HTTP {error.code}).', uncertain=uncertain) from None
            except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
                if method in ('GET', 'PUT') and attempt < 3:
                    self.sleep(2 ** attempt)
                    continue
                raise ApiError(f'{label}: connection failed or timed out.', uncertain=True) from None
            except (ValueError, ET.ParseError):
                raise ApiError(f'{label}: invalid response.', uncertain=True) from None

    def api(self, method, path, body=None):
        return self.request(method, '/v3' + path, body)

    def legacy(self, path):
        return self.request('GET', '/v1' + path)


def digest(path, algorithm='sha256'):
    with path.open('rb') as source:
        return hashlib.file_digest(source, algorithm).hexdigest()


def save_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w', encoding='utf-8') as output:
        json.dump(value, output, indent=2)
        output.write('\n')
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(path)


@contextmanager
def publication_lock(directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'publish.lock'
    try:
        lock = path.open('x', encoding='utf-8')
    except FileExistsError:
        raise ReleaseError(f'Publication is locked: {path}. If its process has stopped, remove this lock.') from None
    try:
        with lock:
            lock.write(str(os.getpid()))
        yield
    finally:
        path.unlink()


class Publisher:
    def __init__(self, root, client=None, sleep=time.sleep):
        self.root = Path(root)
        self.config = json.loads((self.root / 'nexus.json').read_text(encoding='utf-8'))
        self.client = client  # Instantiate lazily: local builds never need credentials.
        self.sleep = sleep
        self.directory = self.root / 'dist' / 'nexus'
        self.target = None

    def configuration(self, version, notes):
        cfg = self.config
        allowed = {'game', 'mod_id', 'file_id', 'create_new_file', 'display_name', 'description',
                   'category', 'archive_existing_file', 'update_mod_version', *DOWNLOAD_OPTIONS}
        if set(cfg) - allowed:
            raise ReleaseError('Unknown nexus.json settings: ' + ', '.join(sorted(set(cfg) - allowed)))
        if not re.fullmatch(r'[a-z0-9_]+', cfg.get('game', '')) or type(cfg.get('mod_id')) is not int or cfg['mod_id'] <= 0:
            raise ReleaseError('nexus.json requires a game domain and a positive website mod_id.')
        if cfg.get('file_id') is not None and (not isinstance(cfg['file_id'], str) or not cfg['file_id']):
            raise ReleaseError('file_id must be a v3 ID string or null.')
        if cfg.get('category') not in ('main', 'optional', 'miscellaneous'):
            raise ReleaseError('Unsupported Nexus file category.')
        name = cfg.get('display_name', '')
        if not isinstance(name, str) or not re.fullmatch(r"[a-zA-Z0-9 _'().-]{1,50}", name):
            raise ReleaseError('Nexus display_name must be 1–50 supported ASCII characters.')
        if not isinstance(cfg.get('description', ''), str):
            raise ReleaseError('Nexus description must be text.')
        if not re.fullmatch(r'[a-zA-Z0-9.-]{1,50}', version) or not 1 <= len(notes) <= 65535:
            raise ReleaseError('Version or changelog exceeds Nexus format/length limits.')
        for key in ('create_new_file', 'archive_existing_file', 'update_mod_version', *DOWNLOAD_OPTIONS):
            if key in cfg and type(cfg[key]) is not bool:
                raise ReleaseError(f'{key} must be a boolean.')
        if cfg.get('create_new_file') and (cfg.get('file_id') or cfg.get('archive_existing_file')):
            raise ReleaseError('New-file mode cannot specify file_id or archive an existing file.')

    @staticmethod
    def ident(value):
        return urllib.parse.quote(str(value), safe='')

    def versions(self, file_id):
        return self.client.api('GET', f'/mod-files/{self.ident(file_id)}/versions')['versions']

    def all_files(self, mod_id):
        files = self.client.api('GET', f'/mods/{self.ident(mod_id)}/files')['mod_files']
        return [(file, self.versions(file['id'])) for file in files]

    def preflight(self, version, notes, receipt=None):
        self.configuration(version, notes)
        if self.client is None:
            self.client = Client()
        self.client.legacy('/users/validate.json')
        cfg = self.config
        mod = self.client.api('GET', f'/games/{cfg["game"]}/mods/{cfg["mod_id"]}')
        if str(mod['game_scoped_id']) != str(cfg['mod_id']):
            raise ReleaseError('Nexus returned a different mod than configured.')
        mod_id = str(mod['id'])
        files = self.all_files(mod_id)
        # Completed new-file creation is an update target on subsequent runs.
        binding_path = self.directory / 'target.json'
        binding = json.loads(binding_path.read_text()) if binding_path.exists() else {}
        bound_id = binding.get('file_id') if binding.get('mod_id') == mod_id else None
        file_id = (receipt or {}).get('file_id') or cfg.get('file_id') or bound_id
        new_file = bool(cfg.get('create_new_file') and not file_id)
        if not file_id and not new_file:
            candidates = []
            for file, versions in files:
                active = [v for v in versions if v['category'] in ('main', 'update', 'optional', 'miscellaneous')]
                latest = max(active, key=lambda v: Decimal(v['position']), default=None)
                if file.get('is_active') and latest and latest['category'] == 'main':
                    candidates.append(file['id'])
            if len(candidates) != 1:
                available = ', '.join(str(file['id']) for file, _ in files) or '(none)'
                raise ReleaseError(f'Expected one main file; configure file_id explicitly. Available IDs: {available}')
            file_id = candidates[0]
        chosen = [(file, versions) for file, versions in files if str(file['id']) == str(file_id)]
        if file_id and len(chosen) != 1:
            raise ReleaseError('Configured file_id does not belong to the configured Nexus mod.')
        # In new-file mode, any same-version entry is reported for review, never guessed.
        versions = chosen[0][1] if chosen else [v for _, entries in files for v in entries]
        duplicates = [v for v in versions if v['version'] == version]
        if duplicates and not receipt:
            raise ReleaseError(f'Nexus version {version} already exists. Use publish-nexus with its receipt to resume.')
        previous = max(chosen[0][1], key=lambda v: Decimal(v['position']), default=None) if chosen else None
        self.target = {'mod_id': mod_id, 'file_id': str(file_id) if file_id else None,
                       'new_file': new_file, 'previous_version_id': previous['id'] if previous else None,
                       'is_primary': previous.get('is_primary') if previous else None}
        if receipt and receipt['mod_id'] != mod_id:
            raise ReleaseError('Receipt belongs to a different Nexus mod.')
        return duplicates

    def wait_available(self, upload_id):
        for attempt in range(20):
            result = self.client.api('GET', f'/uploads/{self.ident(upload_id)}')
            if result['state'] == 'available':
                return
            if result['state'] != 'created':
                raise ReleaseError('Nexus returned an unexpected upload state.')
            self.sleep(min(2 + attempt, 15))
        raise ReleaseError('Nexus upload processing timed out. Resume publication later.')

    def upload(self, archive, state, save):
        if state.get('upload_stage') in ('finalising', 'ready'):
            if state['upload_stage'] == 'finalising':
                status = self.client.api('GET', f'/uploads/{self.ident(state["upload_id"])}')
                if status['state'] == 'created':
                    # Finalisation does not create a public file. The previous
                    # process may have stopped before sending its request.
                    try:
                        self.client.api('POST', f'/uploads/{self.ident(state["upload_id"])}/finalise')
                    except ApiError:
                        # A concurrent/previous finalisation can reject the repeat;
                        # its available state is the authority, not that response.
                        self.wait_available(state['upload_id'])
            self.wait_available(state['upload_id'])
            state['upload_stage'] = 'ready'
            save()
            return
        # Incomplete byte transfers restart with a fresh session because signed
        # URLs are intentionally not persisted. Unclaimed sessions publish nothing.
        size = archive.stat().st_size
        multipart = size > SINGLE_LIMIT
        body = {'filename': archive.name, 'size_bytes': size}
        if not multipart:
            body['md5'] = digest(archive, 'md5')
        result = self.client.api('POST', '/uploads/multipart' if multipart else '/uploads', body)
        state.update(upload_id=result['id'], upload_stage='transferring')
        save()
        if multipart:
            part_size = int(result['part_size_bytes'])
            urls = result['part_presigned_urls']
            if part_size <= 0 or len(urls) != (size + part_size - 1) // part_size:
                raise ReleaseError('Invalid multipart upload geometry.')
            complete = ET.Element('CompleteMultipartUpload')
            transferred = hashlib.sha256()
            with archive.open('rb') as source:
                for number, url in enumerate(urls, 1):
                    data = source.read(part_size)
                    transferred.update(data)
                    headers, _ = self.client.request('PUT', url, raw=data, storage=True,
                                                     headers={'Content-Type': 'application/octet-stream',
                                                              'Content-Length': str(len(data))})
                    etag = next((v for k, v in headers.items() if k.lower() == 'etag'), None)
                    if not etag:
                        raise ReleaseError('Missing multipart ETag.')
                    part = ET.SubElement(complete, 'Part')
                    ET.SubElement(part, 'PartNumber').text = str(number)
                    ET.SubElement(part, 'ETag').text = etag
            if transferred.hexdigest() != state['sha256']:
                raise ReleaseError('ZIP changed during transfer; refusing to complete the upload.')
            self.client.request('POST', result['complete_presigned_url'], raw=ET.tostring(complete),
                                headers={'Content-Type': 'application/xml'}, storage=True)
        else:
            data = archive.read_bytes()
            if hashlib.sha256(data).hexdigest() != state['sha256']:
                raise ReleaseError('ZIP changed before transfer; refusing to upload it.')
            self.client.request('PUT', result['presigned_url'], raw=data, storage=True,
                                headers={'Content-Type': 'application/octet-stream',
                                         'Content-Length': str(len(data)),
                                         'Content-Disposition': f'attachment; filename="{archive.name}"',
                                         'Content-MD5': base64.b64encode(bytes.fromhex(body['md5'])).decode()})
        state['upload_stage'] = 'finalising'
        save()
        try:
            self.client.api('POST', f'/uploads/{self.ident(state["upload_id"])}/finalise')
        except ApiError as error:
            if not error.uncertain:
                state['upload_stage'] = 'transferring'
                save()
            raise
        self.wait_available(state['upload_id'])
        state['upload_stage'] = 'ready'
        save()

    def version_body(self, state, version):
        cfg = self.config
        body = {'upload_id': state['upload_id'], 'name': cfg['display_name'], 'version': version,
                'description': cfg.get('description', ''), 'file_category': cfg['category'],
                'update_mod_version': cfg.get('update_mod_version', True)}
        # v3 exposes the primary flag; preserve it unless explicitly overridden.
        if state.get('is_primary') is not None:
            body['primary_mod_manager_download'] = state['is_primary']
        # Other switches are not exposed by the documented v3 GET response.
        # Omit them unless configuration explicitly pins the site's settings.
        body.update({key: cfg[key] for key in DOWNLOAD_OPTIONS if key in cfg})
        if state['new_file']:
            body['mod_id'] = state['mod_id']
        else:
            body['archive_existing_file'] = cfg.get('archive_existing_file', False)
            if state.get('previous_version_id'):
                body['previous_version_id'] = state['previous_version_id']
        return body

    def reconcile_version(self, state, version, save, adopt_version=None, retry_version=False):
        files = self.all_files(state['mod_id'])
        matches = [v for f, versions in files for v in versions
                   if (state['new_file'] or str(f['id']) == state['file_id']) and v['version'] == version]
        if adopt_version:
            selected = [v for v in matches if str(v['id']) == adopt_version]
            if len(selected) != 1:
                raise ReleaseError('The adopted version must match this mod, file and version string.')
            state.update(file_id=str(selected[0]['file']['id']), version_id=str(selected[0]['id']),
                         version_stage='done')
            save()
            return
        if retry_version and not matches:
            state['version_stage'] = 'pending'
            save()
            return
        candidates = ', '.join(str(v['id']) for v in matches) or '(none visible yet)'
        raise ReleaseError('Version creation has an uncertain outcome. Check Nexus before retrying. '
                           f'Candidate version IDs: {candidates}. After verifying the uploaded ZIP, '
                           'use --adopt-version ID; if creation definitely failed, use --retry-version.')

    def changelog_present(self, version, notes):
        cfg = self.config
        entries = self.client.legacy(f'/games/{cfg["game"]}/mods/{cfg["mod_id"]}/changelogs.json')
        remote = entries.get(version) if isinstance(entries, dict) else None
        normalise = lambda text: text.replace('\r\n', '\n').strip()
        if isinstance(remote, list) and all(isinstance(entry, str) for entry in remote):
            return normalise('\n'.join(remote)) == normalise(notes)
        return isinstance(remote, str) and normalise(remote) == normalise(notes)

    def publish(self, tag, commit, archive, notes, *, adopt_version=None, retry_version=False, changelog_status=None):
        self.directory.mkdir(parents=True, exist_ok=True)
        with publication_lock(self.directory):
            return self._publish(tag, commit, archive, notes, adopt_version, retry_version, changelog_status)

    def _publish(self, tag, commit, archive, notes, adopt_version, retry_version, changelog_status):
        version = tag[1:]
        receipt = self.directory / (tag + '.json')
        state = json.loads(receipt.read_text(encoding='utf-8')) if receipt.exists() else None
        identity = {'tag': tag, 'commit': commit, 'sha256': digest(archive),
                    'notes_sha256': hashlib.sha256(notes.encode()).hexdigest(),
                    'config_sha256': hashlib.sha256(json.dumps(self.config, sort_keys=True).encode()).hexdigest()}
        if state and any(state.get(key) != value for key, value in identity.items()):
            raise ReleaseError('Release bytes, notes, commit or configuration differ from the saved receipt. '
                               'Restore the original artifact/configuration before resuming.')
        duplicates = self.preflight(version, notes, state)
        if not state:
            state = {**identity, **self.target, 'version_stage': 'pending', 'changelog_stage': 'pending'}
        save = lambda: save_json(receipt, state)
        save()
        if state['version_stage'] == 'sending':
            self.reconcile_version(state, version, save, adopt_version, retry_version)
        elif adopt_version or retry_version:
            raise ReleaseError('Version resolution flags apply only to uncertain version creation.')
        if duplicates and state['version_stage'] != 'done':
            raise ReleaseError('This version already exists on Nexus; no new upload was published.')
        if state['version_stage'] == 'done':
            if not any(str(v['id']) == state['version_id'] for v in duplicates):
                raise ReleaseError('The saved Nexus version is no longer present in the selected file.')
        else:
            self.upload(archive, state, save)
            if digest(archive) != state['sha256']:
                raise ReleaseError('Release ZIP changed during upload; refusing to publish.')
            state['version_stage'] = 'sending'
            save()
            try:
                endpoint = '/mod-files' if state['new_file'] else f'/mod-files/{self.ident(state["file_id"])}/versions'
                created = self.client.api('POST', endpoint, self.version_body(state, version))
            except ApiError as error:
                if not error.uncertain:
                    state['version_stage'] = 'pending'
                    save()
                raise
            # Parsing/checkpoint/read failures after a successful POST must leave
            # the operation uncertain, never make it eligible for another POST.
            if state['new_file']:
                state['file_id'] = str(created['id'])
                save()
                versions = [v for v in self.versions(state['file_id']) if v['version'] == version]
                if len(versions) != 1:
                    raise ReleaseError('New file created; its version needs reconciliation on resume.')
                state['version_id'] = str(versions[0]['id'])
            else:
                state['version_id'] = str(created['version']['id'])
            state['version_stage'] = 'done'
            save()
        save_json(self.directory / 'target.json', {'mod_id': state['mod_id'], 'file_id': state['file_id']})
        if changelog_status and state['changelog_stage'] != 'sending':
            raise ReleaseError('Changelog resolution applies only to an uncertain submission.')
        if state['changelog_stage'] == 'sending':
            if changelog_status == 'posted':
                state['changelog_stage'] = 'done'
            elif changelog_status == 'not-posted':
                state['changelog_stage'] = 'pending'
            elif self.changelog_present(version, notes):
                state['changelog_stage'] = 'done'
            else:
                raise ReleaseError('Changelog submission is uncertain. Inspect Nexus, then resume with '
                                   '--changelog-status posted or --changelog-status not-posted.')
            save()
        if state['changelog_stage'] != 'done':
            state['changelog_stage'] = 'sending'
            save()
            try:
                self.client.api('POST', f'/mods/{self.ident(state["mod_id"])}/changelogs',
                                {'version': version, 'changelog': notes})
            except ApiError as error:
                if not error.uncertain:
                    state['changelog_stage'] = 'pending'
                    save()
                raise
            state['changelog_stage'] = 'done'
            save()
        print(f'Nexus publication complete: {tag}, version ID {state["version_id"]}')
        return state['version_id']
