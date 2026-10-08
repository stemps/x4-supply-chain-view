"""Discord release announcement through a channel webhook, with a durable receipt.

discord.json names the target channel and the environment variable holding its webhook
URL, so each mod can announce in its own channel. The URL is a secret (anyone holding it
can post to the channel): it is never written to receipts, logs or error messages; the
receipt stores only the webhook's numeric id. Forum channels need "forum": true, which
creates a new post titled like the message heading.
Contract: https://discord.com/developers/docs/resources/webhook (checked October 2026).
"""
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.request

from release_archive import ReleaseError
from nexus_publish import save_json, publication_lock

WEBHOOK = re.compile(r'https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/(\d+)/[\w-]+')
LIMIT = 2000  # Message content limit for webhooks; Nitro limits do not apply.
SUPPRESS_EMBEDS = 1 << 2


def title(name, tag):
    return f'Release {name} {tag}'


def message(name, tag, links, notes):
    lines = [f'# {title(name, tag)}', '## Download from:', '']
    lines += [f'* [{label}]({url})' for label, url in links]
    lines += ['', '', '## Changes', '', notes.strip()]
    return '\n'.join(lines)


class DiscordPublisher:
    def __init__(self, root, url=None, opener=None, sleep=time.sleep):
        self.root = Path(root)
        path = self.root / 'discord.json'
        self.config = json.loads(path.read_text(encoding='utf-8')) if path.exists() else None
        if self.config is not None:
            self.configuration()
        self.url = url if url is not None else os.environ.get(self.env, '').strip() if self.config else ''
        self.opener = opener or urllib.request.build_opener()
        self.sleep = sleep
        self.directory = self.root / 'dist' / 'discord'

    def configuration(self):
        cfg = self.config
        if set(cfg) - {'channel_id', 'webhook_env', 'forum'}:
            raise ReleaseError('Unknown discord.json settings: ' + ', '.join(sorted(set(cfg) - {
                'channel_id', 'webhook_env', 'forum'})))
        if not isinstance(cfg.get('channel_id'), str) or not cfg['channel_id'].isdigit():
            raise ReleaseError('discord.json channel_id must be the channel id as a string of digits.')
        if not re.fullmatch(r'[A-Z][A-Z0-9_]*', str(cfg.get('webhook_env', ''))):
            raise ReleaseError('discord.json webhook_env must name an environment variable, e.g. X4_DISCORD_WEBHOOK_SCV.')
        if type(cfg.get('forum', False)) is not bool:
            raise ReleaseError('discord.json forum must be true or false.')

    @property
    def env(self):
        return self.config['webhook_env']

    @property
    def enabled(self):
        # A discord.json makes the announcement part of every release; a missing URL is then an error.
        return self.config is not None

    def webhook_id(self):
        if not self.url:
            raise ReleaseError(f'Set {self.env} to the webhook URL of Discord channel {self.config["channel_id"]}.')
        match = WEBHOOK.fullmatch(self.url)
        if not match:
            raise ReleaseError(f'{self.env} is not a Discord webhook URL '
                               '(https://discord.com/api/webhooks/<id>/<token>).')
        return match.group(1)

    def links(self):
        nexus = json.loads((self.root / 'nexus.json').read_text(encoding='utf-8'))
        links = [('Nexus', f'https://www.nexusmods.com/{nexus["game"]}/mods/{nexus["mod_id"]}')]
        steam_path = self.root / 'steam.json'
        steam = json.loads(steam_path.read_text(encoding='utf-8')) if steam_path.exists() else {}
        if steam.get('published_file_id'):
            links.append(('Steam', 'https://steamcommunity.com/sharedfiles/filedetails/?id='
                          + steam['published_file_id']))
        return nexus['display_name'], links

    def content(self, tag, notes):
        name, links = self.links()
        text = message(name, tag, links, notes)
        if len(text) > LIMIT:
            raise ReleaseError(f'Discord announcement is {len(text)} characters; the limit is {LIMIT}. '
                               'Shorten the release notes.')
        return text

    def request(self, method, body=None):
        data = json.dumps(body).encode() if body is not None else None
        query = '?wait=true' if method == 'POST' else ''
        request = urllib.request.Request(self.url + query, data=data, method=method,
                                         headers={'Content-Type': 'application/json',
                                                  'User-Agent': 'x4-mod-release/1.0'})
        with self.opener.open(request, timeout=30) as response:
            return json.loads(response.read() or b'{}')

    @staticmethod
    def reason(error):
        try:
            detail = json.loads(error.read()).get('message', '')
        except (ValueError, OSError, AttributeError):
            detail = ''
        return f'HTTP {error.code}' + (f': {detail}' if detail else '')

    def preflight(self, version, notes):
        """Release preflight: a reachable webhook and an announcement that fits, before tagging."""
        self.webhook_id()
        self.content('v' + version, notes)
        try:
            # GET with the token returns the webhook without posting anything.
            channel = str(self.request('GET').get('channel_id', ''))
        except urllib.error.HTTPError as error:
            raise ReleaseError(f'Discord webhook check failed ({self.reason(error)}). '
                               'Was the webhook deleted or the URL mistyped?') from None
        except (urllib.error.URLError, TimeoutError) as error:
            raise ReleaseError(f'Discord webhook check failed: {getattr(error, "reason", error)}') from None
        if channel != self.config['channel_id']:
            raise ReleaseError(f'{self.env} posts to channel {channel or "?"}, but discord.json expects '
                               f'{self.config["channel_id"]}. Is it the other mod\'s webhook?')

    def published_elsewhere(self, tag):
        """Announce only what is downloadable: Nexus must be done; Steam, if recorded, too."""
        nexus = self.root / 'dist' / 'nexus' / (tag + '.json')
        state = json.loads(nexus.read_text(encoding='utf-8')) if nexus.exists() else {}
        if state.get('version_stage') != 'done':
            raise ReleaseError(f'Nexus publication of {tag} is not recorded as complete. '
                               f'Run just publish-nexus {tag} first.')
        steam = self.root / 'dist' / 'steam' / (tag + '.json')
        if steam.exists():
            if json.loads(steam.read_text(encoding='utf-8')).get('upload_stage') != 'done':
                raise ReleaseError(f'Steam publication of {tag} is incomplete. Run just publish-steam {tag} first.')
        elif any(label == 'Steam' for label, _ in self.links()[1]):
            print(f'Note: no Steam receipt for {tag}; the Steam link is announced without a recorded upload.')

    def publish(self, tag, commit, notes, *, confirm_posted=False, retry=False):
        if not self.enabled:
            raise ReleaseError('discord.json is missing.')
        self.directory.mkdir(parents=True, exist_ok=True)
        with publication_lock(self.directory):
            return self._publish(tag, commit, notes, confirm_posted, retry)

    def _publish(self, tag, commit, notes, confirm_posted, retry):
        webhook = self.webhook_id()
        text = self.content(tag, notes)
        receipt = self.directory / (tag + '.json')
        state = json.loads(receipt.read_text(encoding='utf-8')) if receipt.exists() else None
        identity = {'tag': tag, 'commit': commit, 'webhook_id': webhook,
                    'content_sha256': hashlib.sha256(text.encode()).hexdigest()}
        if state and state['stage'] != 'pending' and any(state.get(k) != v for k, v in identity.items()):
            raise ReleaseError('Announcement text, commit or webhook differ from the saved receipt '
                               f'(dist/discord/{tag}.json).')
        if not state or state['stage'] == 'pending':
            state = {**identity, 'stage': 'pending'}
        save = lambda: save_json(receipt, state)
        if state['stage'] == 'done':
            if confirm_posted or retry:
                raise ReleaseError('This release is already announced on Discord.')
            print(f'Discord announcement already posted: {tag}')
            return state
        if state['stage'] == 'sending':
            if confirm_posted:
                state['stage'] = 'done'
                save()
                print(f'Discord announcement recorded as posted: {tag}')
                return state
            if not retry:
                raise ReleaseError('The previous Discord post has an uncertain outcome. Check the channel, then '
                                   'resume with --confirm-posted or --retry-post.')
        elif confirm_posted or retry:
            raise ReleaseError('Discord resolution flags apply only to an uncertain post; the last attempt '
                               'posted nothing. Resume without --confirm-posted/--retry-post.')
        self.published_elsewhere(tag)
        # Check the channel again: the receipt binds the webhook id, not where it points today.
        self.preflight(tag[1:], notes)
        body = {'content': text, 'flags': SUPPRESS_EMBEDS, 'allowed_mentions': {'parse': []}}
        if self.config.get('forum'):
            body['thread_name'] = title(self.links()[0], tag)
        for attempt in range(4):
            state['stage'] = 'sending'
            save()
            try:
                result = self.request('POST', body)
            except urllib.error.HTTPError as error:
                if error.code == 429 and attempt < 3:
                    # Rate limited: Discord rejected the message, so retrying cannot duplicate it.
                    try:
                        delay = float(json.loads(error.read()).get('retry_after', 2))
                    except (ValueError, OSError, AttributeError):
                        delay = 2.0
                    state['stage'] = 'pending'
                    save()
                    self.sleep(min(delay, 60))
                    continue
                if error.code < 500:
                    state['stage'] = 'pending'
                    save()
                    raise ReleaseError(f'Discord rejected the announcement ({self.reason(error)}); '
                                       'nothing was posted.') from None
                raise ReleaseError(f'Discord returned {self.reason(error)}; the post outcome is uncertain.') from None
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                raise ReleaseError(f'Discord request failed ({getattr(error, "reason", error)}); '
                                   'the post outcome is uncertain.') from None
            state['stage'] = 'done'
            state['message_id'] = str(result.get('id', ''))
            save()
            print(f'Discord announcement posted: {tag}')
            return state
        state['stage'] = 'pending'
        save()
        raise ReleaseError('Discord kept rate limiting the announcement; nothing was posted.')
