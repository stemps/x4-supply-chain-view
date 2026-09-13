"""Nexus lifecycle and transport tests. All HTTP responses are fakes."""
import base64
import copy
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from nexus_publish import Publisher, Client, ApiError, ReleaseError, publication_lock


class FakeNexus:
    def __init__(self):
        self.files = {'file-1': [{'id': 'old', 'file': {'id': 'file-1'}, 'version': '0.1.0',
                                  'category': 'main', 'position': '1', 'is_primary': True}]}
        self.uploads = {}
        self.calls = []
        self.notes = {}
        self.transfer_failure = False
        self.creation_failure = False
        self.changelog_failure = False
        self.finalise_timeout = False
        self.reject_changelog = False
        self.auth_failure = False
        self.multipart = False

    def legacy(self, path):
        if self.auth_failure:
            raise ApiError('HTTP 403')
        if path == '/users/validate.json':
            return {'user_id': 1}
        return self.notes

    def api(self, method, path, body=None):
        self.calls.append((method, path, copy.deepcopy(body)))
        if method == 'GET':
            if path.startswith('/games/'):
                return {'id': 'mod-2371', 'game_scoped_id': '2371'}
            if path.endswith('/files'):
                return {'mod_files': [{'id': key, 'is_active': True} for key in self.files]}
            if path.endswith('/versions'):
                return {'versions': copy.deepcopy(self.files[path.split('/')[2]])}
            if path.startswith('/uploads/'):
                return {'state': self.uploads[path.split('/')[2]]}
        if path in ('/uploads', '/uploads/multipart'):
            uid = 'upload-' + str(len(self.uploads) + 1)
            self.uploads[uid] = 'created'
            if path.endswith('/multipart'):
                self.multipart = True
                return {'id': uid, 'part_size_bytes': 5,
                        'part_presigned_urls': ['https://storage/part'] * ((body['size_bytes'] + 4) // 5),
                        'complete_presigned_url': 'https://storage/complete'}
            return {'id': uid, 'presigned_url': 'https://storage/file'}
        if path.endswith('/finalise'):
            if not self.finalise_timeout:
                self.uploads[path.split('/')[2]] = 'available'
            return {}
        if path.endswith('/versions') or path == '/mod-files':
            file_id = path.split('/')[2] if path != '/mod-files' else 'new-file'
            self.files.setdefault(file_id, []).append({'id': 'new-version', 'file': {'id': file_id},
                                                      'version': body['version'], 'category': 'main', 'position': '2'})
            if self.creation_failure:
                raise ApiError('lost creation response', uncertain=True)
            return {'id': file_id} if path == '/mod-files' else {'version': {'id': 'new-version'}}
        if path.endswith('/changelogs'):
            if self.reject_changelog:
                raise ApiError('HTTP 422')
            self.notes.setdefault(body['version'], []).append(body['changelog'])
            if self.changelog_failure:
                raise ApiError('lost changelog response', uncertain=True)
            return {}
        raise AssertionError((method, path, body))

    def request(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if self.transfer_failure:
            raise ApiError('interrupted transfer', uncertain=True)
        return {'ETag': '"etag"'}, b''


class PublishTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = json.loads((Path(__file__).resolve().parents[1] / 'nexus.json').read_text())
        self.write_config()
        self.archive = self.root / 'Supply-Chain-View-0.2.0.zip'
        self.archive.write_bytes(b'archive bytes for transport tests')
        self.fake = FakeNexus()

    def write_config(self):
        (self.root / 'nexus.json').write_text(json.dumps(self.config))

    def publisher(self):
        return Publisher(self.root, client=self.fake, sleep=lambda _: None)

    def publish(self, **kwargs):
        return self.publisher().publish('v0.2.0', 'commit', self.archive, '- Reviewed notes', **kwargs)

    def receipt(self):
        return json.loads((self.root / 'dist/nexus/v0.2.0.json').read_text())

    def posts(self, suffix):
        return [call for call in self.fake.calls if call[0] == 'POST' and call[1].endswith(suffix)]

    def test_success_and_repeat_do_not_duplicate(self):
        self.assertEqual(self.publish(), 'new-version')
        self.publish()
        self.assertEqual(len(self.posts('/versions')), 1)
        self.assertEqual(len(self.posts('/changelogs')), 1)
        body = self.posts('/versions')[0][2]
        self.assertEqual(body['version'], '0.2.0')
        self.assertTrue(body['update_mod_version'])
        self.assertFalse(body['archive_existing_file'])
        self.assertEqual(body['previous_version_id'], 'old')
        self.assertNotIn('allow_mod_manager_download', body)
        self.assertTrue(body['primary_mod_manager_download'])
        self.assertEqual(self.receipt()['changelog_stage'], 'done')
        receipt_text = json.dumps(self.receipt())
        self.assertNotIn('https://', receipt_text)
        self.assertNotIn('apikey', receipt_text)
        put = next(call for call in self.fake.calls if call[0] == 'PUT')
        md5 = hashlib.md5(self.archive.read_bytes()).digest()
        self.assertEqual(put[2]['headers']['Content-MD5'], base64.b64encode(md5).decode())
        self.assertEqual(put[2]['headers']['Content-Disposition'], f'attachment; filename="{self.archive.name}"')

    def test_auth_duplicate_and_ambiguous_target_fail_before_upload(self):
        self.fake.auth_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.fake.auth_failure = False
        with self.assertRaisesRegex(ReleaseError, 'already exists'):
            self.publisher().preflight('0.1.0', 'notes')
        self.fake.files['file-2'] = copy.deepcopy(self.fake.files['file-1'])
        with self.assertRaisesRegex(ReleaseError, 'Expected one main file'):
            self.publish()
        self.assertEqual(self.posts('/uploads'), [])
        self.config['file_id'] = 'file-1'
        self.write_config()
        self.publish()

    def test_new_file_creation_and_next_release_binding(self):
        self.config['create_new_file'] = True
        self.write_config()
        self.fake.files = {}
        self.publish()
        self.assertEqual(len(self.posts('/mod-files')), 1)
        self.assertEqual(self.receipt()['file_id'], 'new-file')
        self.publish()
        pub = self.publisher()
        pub.preflight('0.3.0', 'next')
        self.assertEqual(pub.target['file_id'], 'new-file')
        self.assertFalse(pub.target['new_file'])

    def test_new_file_read_failure_does_not_create_second_file(self):
        self.config['create_new_file'] = True
        self.write_config()
        self.fake.files = {}
        original_api = self.fake.api
        def fail_read(method, path, body=None):
            if path == '/mod-files/new-file/versions':
                raise ApiError('HTTP 403')
            return original_api(method, path, body)
        with patch.object(self.fake, 'api', side_effect=fail_read):
            with self.assertRaises(ApiError):
                self.publish()
        self.assertEqual(self.receipt()['version_stage'], 'sending')
        self.publish(adopt_version='new-version')
        self.assertEqual(len(self.posts('/mod-files')), 1)

    def test_uncertain_creation_confirmed_absent_can_retry(self):
        self.fake.creation_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.fake.files['file-1'].pop()
        self.fake.creation_failure = False
        self.publish(retry_version=True)
        self.assertEqual(len(self.posts('/uploads')), 1)
        self.assertEqual(len(self.posts('/versions')), 2)

    def test_interrupted_transfer_restarts_unclaimed_upload_only(self):
        self.fake.transfer_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.assertEqual(self.posts('/versions'), [])
        self.fake.transfer_failure = False
        self.publish()
        self.assertEqual(len(self.posts('/uploads')), 2)
        self.assertEqual(len(self.posts('/versions')), 1)

    def test_processing_timeout_resumes_existing_upload(self):
        self.fake.finalise_timeout = True
        with self.assertRaisesRegex(ReleaseError, 'processing timed out'):
            self.publish()
        self.fake.finalise_timeout = False
        self.publish()
        self.assertEqual(len(self.posts('/uploads')), 1)

    def test_ambiguous_version_never_reposts_without_resolution(self):
        self.fake.creation_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.assertEqual(self.receipt()['version_stage'], 'sending')
        with self.assertRaisesRegex(ReleaseError, 'uncertain outcome'):
            self.publish()
        self.fake.creation_failure = False
        self.publish(adopt_version='new-version')
        self.assertEqual(len(self.posts('/versions')), 1)

    def test_ambiguous_changelog_reconciles_exact_text(self):
        self.fake.changelog_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.fake.changelog_failure = False
        self.publish()
        self.assertEqual(len(self.posts('/changelogs')), 1)

    def test_uncertain_changelog_requires_explicit_absence(self):
        self.fake.changelog_failure = True
        with self.assertRaises(ApiError):
            self.publish()
        self.fake.notes = {}  # Simulate loss before the server processed the write.
        self.fake.changelog_failure = False
        with self.assertRaisesRegex(ReleaseError, 'submission is uncertain'):
            self.publish()
        self.assertEqual(len(self.posts('/changelogs')), 1)
        self.publish(changelog_status='not-posted')
        self.assertEqual(len(self.posts('/versions')), 1)
        self.assertEqual(len(self.posts('/changelogs')), 2)

    def test_definite_changelog_rejection_can_retry(self):
        self.fake.reject_changelog = True
        with self.assertRaises(ApiError):
            self.publish()
        self.assertEqual(self.receipt()['changelog_stage'], 'pending')
        self.fake.reject_changelog = False
        self.publish()
        self.assertEqual(len(self.posts('/versions')), 1)

    def test_mutated_artifact_or_config_rejected(self):
        self.publish()
        self.archive.write_bytes(b'changed')
        with self.assertRaisesRegex(ReleaseError, 'differ from the saved receipt'):
            self.publish()
        self.assertEqual(len(self.posts('/versions')), 1)

    def test_changed_configuration_rejected_on_resume(self):
        self.publish()
        self.config['archive_existing_file'] = True
        self.write_config()
        with self.assertRaisesRegex(ReleaseError, 'differ from the saved receipt'):
            self.publish()

    def test_multipart_transfer(self):
        with patch('nexus_publish.SINGLE_LIMIT', 1):
            self.publish()
        self.assertTrue(self.fake.multipart)
        completion = self.posts('/complete')[0][2]['raw']
        self.assertIn(b'<PartNumber>1</PartNumber>', completion)
        self.assertIn(b'<ETag>"etag"</ETag>', completion)

    def test_changed_bytes_during_multipart_are_not_published(self):
        original = self.fake.request
        def mutate(method, path, **kwargs):
            if method == 'PUT':
                self.archive.write_bytes(b'X' * self.archive.stat().st_size)
            return original(method, path, **kwargs)
        # Disable buffered read-ahead so the simulated edit affects later parts.
        original_open = Path.open
        def unbuffered(path, *args, **kwargs):
            if path == self.archive and args and args[0] == 'rb':
                kwargs['buffering'] = 0
            return original_open(path, *args, **kwargs)
        with patch('nexus_publish.SINGLE_LIMIT', 1), patch.object(self.fake, 'request', side_effect=mutate), \
                patch.object(Path, 'open', unbuffered):
            with self.assertRaisesRegex(ReleaseError, 'changed during transfer'):
                self.publish()
        self.assertEqual(self.posts('/versions'), [])
        self.assertEqual(self.receipt()['upload_stage'], 'transferring')

    def test_concurrent_publisher_rejected(self):
        with publication_lock(self.root / 'dist/nexus'):
            with self.assertRaisesRegex(ReleaseError, 'locked'):
                self.publish()


class Response(io.BytesIO):
    def __init__(self, payload, headers=None):
        super().__init__(payload)
        self.headers = headers or {}


class Opener:
    def __init__(self, responses):
        self.responses = iter(responses)
        self.requests = []

    def open(self, request, timeout):
        self.requests.append(request)
        result = next(self.responses)
        if isinstance(result, Exception):
            raise result
        return result


class TransportTests(unittest.TestCase):
    def test_rate_limit_and_authenticated_headers(self):
        error = urllib.error.HTTPError('https://api.nexusmods.com', 429, 'limit', {'Retry-After': '3'}, None)
        opener = Opener([error, Response(b'{"data": {"id": "ok"}}')])
        delays = []
        client = Client('SECRET', opener, sleep=delays.append)
        self.assertEqual(client.api('GET', '/mods/x'), {'id': 'ok'})
        self.assertEqual(delays, [3])
        self.assertEqual(opener.requests[0].get_header('Apikey'), 'SECRET')

    def test_post_timeout_is_not_retried_or_leaked(self):
        opener = Opener([urllib.error.URLError('SECRET in diagnostic')])
        with self.assertRaises(ApiError) as caught:
            Client('SECRET', opener).api('POST', '/mod-files/x/versions', {})
        self.assertTrue(caught.exception.uncertain)
        self.assertNotIn('SECRET', str(caught.exception))
        self.assertEqual(len(opener.requests), 1)

    def test_storage_has_no_key_and_does_not_log_signed_url(self):
        opener = Opener([Response(b'', {'ETag': 'etag'})])
        Client('SECRET', opener).request('PUT', 'https://storage/x?signature=PRIVATE',
                                        raw=b'zip', storage=True)
        self.assertIsNone(opener.requests[0].get_header('Apikey'))

    def test_multipart_error_with_http_success(self):
        opener = Opener([Response(b'<Error><Code>InternalError</Code></Error>')])
        with self.assertRaises(ApiError):
            Client('SECRET', opener).request('POST', 'https://storage/complete', raw=b'xml', storage=True)


if __name__ == '__main__':
    unittest.main()
