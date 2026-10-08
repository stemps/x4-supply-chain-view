"""Discord announcement tests. All HTTP responses are fakes; no webhook is contacted."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
import urllib.error

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'scripts'))
from discord_publish import DiscordPublisher, LIMIT, SUPPRESS_EMBEDS
from release_archive import ReleaseError

URL = 'https://discord.com/api/webhooks/111/secret-token'
CHANNEL = '222'
NOTES = '- Fix a thing\n- Add @everyone-proof notes'


class Response(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def http_error(code, body=b'{}'):
    return urllib.error.HTTPError(URL, code, 'error', {}, io.BytesIO(body))


class FakeDiscord:
    """Answers GET with the webhook's channel; POST outcomes are scripted per call."""
    def __init__(self, channel=CHANNEL, posts=()):
        self.channel = channel
        self.posts = list(posts)
        self.sent = []

    def open(self, request, timeout=None):
        if request.get_method() == 'GET':
            return Response(json.dumps({'id': '111', 'channel_id': self.channel}).encode())
        self.sent.append((request.full_url, json.loads(request.data)))
        outcome = self.posts.pop(0) if self.posts else None
        if isinstance(outcome, Exception):
            raise outcome
        return Response(json.dumps({'id': '999'}).encode())


class DiscordTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        (self.root / 'nexus.json').write_text(json.dumps(
            {'game': 'x4foundations', 'mod_id': 2405, 'display_name': 'Civilian Economy'}), encoding='utf-8')
        (self.root / 'steam.json').write_text(json.dumps({'appid': 392160, 'published_file_id': '3811529417'}),
                                              encoding='utf-8')
        self.configure()
        self.receipt('nexus', {'version_stage': 'done'})
        self.receipt('steam', {'upload_stage': 'done'})
        self.sleeps = []

    def configure(self, **extra):
        (self.root / 'discord.json').write_text(json.dumps(
            {'channel_id': CHANNEL, 'webhook_env': 'X4_DISCORD_WEBHOOK_CE', **extra}), encoding='utf-8')

    def receipt(self, kind, state, tag='v0.1.2'):
        (self.root / 'dist' / kind).mkdir(parents=True, exist_ok=True)
        (self.root / 'dist' / kind / (tag + '.json')).write_text(json.dumps(state), encoding='utf-8')

    def publisher(self, fake, url=URL):
        return DiscordPublisher(self.root, url=url, opener=fake, sleep=self.sleeps.append)

    def state(self):
        return json.loads((self.root / 'dist' / 'discord' / 'v0.1.2.json').read_text(encoding='utf-8'))

    def test_posts_the_requested_format_once(self):
        fake = FakeDiscord()
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        url, body = fake.sent[0]
        self.assertEqual(url, URL + '?wait=true')
        self.assertEqual(body['content'], '# Release Civilian Economy v0.1.2\n## Download from:\n\n'
                         '* [Nexus](https://www.nexusmods.com/x4foundations/mods/2405)\n'
                         '* [Steam](https://steamcommunity.com/sharedfiles/filedetails/?id=3811529417)\n\n\n'
                         '## Changes\n\n' + NOTES)
        self.assertEqual(body['flags'], SUPPRESS_EMBEDS)
        self.assertEqual(body['allowed_mentions'], {'parse': []})
        self.assertNotIn('thread_name', body)
        self.assertEqual(self.state()['stage'], 'done')
        self.assertEqual(self.state()['message_id'], '999')
        # The secret token never reaches the receipt.
        self.assertNotIn('secret-token', (self.root / 'dist' / 'discord' / 'v0.1.2.json').read_text())
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertEqual(len(fake.sent), 1)

    def test_forum_channel_creates_a_titled_post(self):
        self.configure(forum=True)
        fake = FakeDiscord()
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertEqual(fake.sent[0][1]['thread_name'], 'Release Civilian Economy v0.1.2')

    def test_steam_link_omitted_without_item(self):
        (self.root / 'steam.json').unlink()
        (self.root / 'dist' / 'steam' / 'v0.1.2.json').unlink()
        fake = FakeDiscord()
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertNotIn('Steam', fake.sent[0][1]['content'])

    def test_wrong_channel_is_refused_before_posting(self):
        fake = FakeDiscord(channel='333')
        with self.assertRaisesRegex(ReleaseError, 'other mod'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        with self.assertRaisesRegex(ReleaseError, 'other mod'):
            self.publisher(fake).preflight('0.1.2', NOTES)
        self.assertEqual(fake.sent, [])

    def test_missing_or_malformed_url(self):
        for url, message in (('', 'Set X4_DISCORD_WEBHOOK_CE'), ('https://example.com/hook', 'not a Discord')):
            with self.subTest(url=url), self.assertRaisesRegex(ReleaseError, message):
                self.publisher(FakeDiscord(), url=url).preflight('0.1.2', NOTES)

    def test_no_discord_json_disables(self):
        (self.root / 'discord.json').unlink()
        self.assertFalse(DiscordPublisher(self.root, url=URL).enabled)

    def test_bad_configuration(self):
        for cfg in ({'channel_id': 222, 'webhook_env': 'X'}, {'channel_id': '1', 'webhook_env': 'lower'},
                    {'channel_id': '1', 'webhook_env': 'X', 'forum': 'yes'},
                    {'channel_id': '1', 'webhook_env': 'X', 'other': 1}):
            (self.root / 'discord.json').write_text(json.dumps(cfg), encoding='utf-8')
            with self.subTest(cfg=cfg), self.assertRaises(ReleaseError):
                DiscordPublisher(self.root, url=URL)

    def test_too_long_is_refused_in_preflight(self):
        with self.assertRaisesRegex(ReleaseError, 'limit'):
            self.publisher(FakeDiscord()).preflight('0.1.2', '- x' * LIMIT)

    def test_requires_completed_publications(self):
        self.receipt('nexus', {'version_stage': 'sending'})
        with self.assertRaisesRegex(ReleaseError, 'Nexus'):
            self.publisher(FakeDiscord()).publish('v0.1.2', 'abc', NOTES)
        self.receipt('nexus', {'version_stage': 'done'})
        self.receipt('steam', {'upload_stage': 'sending'})
        with self.assertRaisesRegex(ReleaseError, 'Steam'):
            self.publisher(FakeDiscord()).publish('v0.1.2', 'abc', NOTES)

    def test_rejection_is_certain_and_retryable(self):
        fake = FakeDiscord(posts=[http_error(400, b'{"message": "Invalid Form Body"}')])
        with self.assertRaisesRegex(ReleaseError, 'Invalid Form Body.*nothing was posted'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertEqual(self.state()['stage'], 'pending')
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertEqual(self.state()['stage'], 'done')

    def test_rate_limit_waits_and_retries(self):
        fake = FakeDiscord(posts=[http_error(429, b'{"retry_after": 1.5}')])
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.assertEqual(self.sleeps, [1.5])
        self.assertEqual(len(fake.sent), 2)

    def test_uncertain_outcome_needs_resolution(self):
        fake = FakeDiscord(posts=[http_error(502)])
        with self.assertRaisesRegex(ReleaseError, 'uncertain'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        with self.assertRaisesRegex(ReleaseError, '--confirm-posted or --retry-post'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES, confirm_posted=True)
        self.assertEqual(len(fake.sent), 1)
        self.assertEqual(self.state()['stage'], 'done')

    def test_uncertain_outcome_retry_posts_again(self):
        fake = FakeDiscord(posts=[urllib.error.URLError('timed out')])
        with self.assertRaisesRegex(ReleaseError, 'uncertain'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES, retry=True)
        self.assertEqual(len(fake.sent), 2)

    def test_resolution_flags_need_an_uncertain_post(self):
        with self.assertRaisesRegex(ReleaseError, 'posted nothing'):
            self.publisher(FakeDiscord()).publish('v0.1.2', 'abc', NOTES, retry=True)

    def test_changed_text_after_posting_is_refused(self):
        fake = FakeDiscord()
        self.publisher(fake).publish('v0.1.2', 'abc', NOTES)
        with self.assertRaisesRegex(ReleaseError, 'differ'):
            self.publisher(fake).publish('v0.1.2', 'abc', NOTES + '\n- more')

    def test_live_configuration_is_valid(self):
        root = Path(__file__).resolve().parents[2]
        if (root / 'discord.json').exists():
            DiscordPublisher(root, url=URL)


if __name__ == '__main__':
    unittest.main()
