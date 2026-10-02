"""Steam Workshop publisher: Egosoft WorkshopTool 'update' in batch mode, with a durable receipt.

Steam has no Web API for uploading Workshop content, and SteamCMD cannot update
X4 items (MEASURED: "no workshop depot found"; X4 uses file-based Workshop items).
WorkshopTool, from the free "X Tools" app, uses the running and logged-in Steam
client, so no credentials are handled here.
"""
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.parse
import urllib.request

from release_archive import ReleaseError
from nexus_publish import save_json, publication_lock
import workshop_build

DETAILS = 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/'
DEFAULT_TOOL = r'C:\Program Files (x86)\Steam\steamapps\common\X Tools\WorkshopTool.exe'


def item_details(item):
    """Public details, or None when Steam does not show the item anonymously (e.g. hidden)."""
    body = urllib.parse.urlencode({'itemcount': 1, 'publishedfileids[0]': item}).encode()
    request = urllib.request.Request(DETAILS, data=body, method='POST',
                                     headers={'User-Agent': 'x4-mod-release/1.0'})
    with urllib.request.urlopen(request, timeout=30) as response:
        details = json.loads(response.read())['response']['publishedfiledetails'][0]
    return details if details.get('result') == 1 else None


def steam_running():
    if os.name != 'nt':
        return True  # WorkshopTool is Windows-only; let it report its own errors elsewhere.
    result = subprocess.run(['tasklist', '/FI', 'IMAGENAME eq steam.exe', '/NH'],
                            capture_output=True, text=True)
    return 'steam.exe' in result.stdout.lower()


def update_command(tool, folder, notes, minor):
    # Without -namedesc, WorkshopTool leaves the Workshop title and description alone.
    command = [tool, 'update', '-path', str(Path(folder).resolve()), '-changenote', notes, '-batchmode']
    return command + ['-minor'] if minor else command


class SteamPublisher:
    def __init__(self, root, run=subprocess.run, details=item_details, running=steam_running, clock=time.time):
        self.root = Path(root)
        self.config = workshop_build.config(self.root)
        self.directory = self.root / 'dist' / 'steam'
        self.run = run
        self.details = details
        self.running = running
        self.clock = clock

    @property
    def enabled(self):
        # Without an item id there is nothing to update yet; releases skip Steam.
        return bool(self.config and self.config.get('published_file_id'))

    def workshoptool(self):
        return workshop_build.tool(self.root, 'X4_WORKSHOPTOOL', None,
                                   DEFAULT_TOOL if Path(DEFAULT_TOOL).is_file() else 'WorkshopTool')

    def preflight(self, version=None, notes=None):
        if not self.config.get('published_file_id'):
            raise ReleaseError('steam.json has no published_file_id. Create the Workshop item first.')
        self.workshoptool()
        workshop_build.xrcattool(self.root)
        if not self.running():
            raise ReleaseError('Start the Steam client and log in; WorkshopTool uploads through it.')
        details = self.details(self.config['published_file_id'])
        if details is None:
            print('Note: the Workshop item is not publicly visible, so its identity cannot be checked anonymously.')
        elif details.get('consumer_app_id') != self.config['appid']:
            raise ReleaseError('steam.json published_file_id belongs to a different game.')
        return details

    def publish(self, tag, commit, folder, digest, notes, *, confirm_uploaded=False, retry=False, minor=False):
        self.directory.mkdir(parents=True, exist_ok=True)
        with publication_lock(self.directory):
            return self._publish(tag, commit, folder, digest, notes, confirm_uploaded, retry, minor)

    def _publish(self, tag, commit, folder, digest, notes, confirm_uploaded, retry, minor):
        receipt = self.directory / (tag + '.json')
        state = json.loads(receipt.read_text(encoding='utf-8')) if receipt.exists() else None
        identity = {'tag': tag, 'commit': commit, 'content_sha256': digest,
                    'published_file_id': self.config['published_file_id']}
        if state and any(state.get(key) != value for key, value in identity.items()):
            raise ReleaseError('Release content, commit or Workshop item differ from the saved receipt.')
        state = state or {**identity, 'upload_stage': 'pending'}
        save = lambda: save_json(receipt, state)
        if state['upload_stage'] == 'done':
            if confirm_uploaded or retry:
                raise ReleaseError('This release is already published on Steam.')
            print(f'Steam Workshop publication already complete: {tag}')
            return state
        if state['upload_stage'] == 'sending':
            if confirm_uploaded:
                state['upload_stage'] = 'done'
                save()
                print(f'Steam Workshop publication recorded as complete: {tag}')
                return state
            if not retry:
                raise ReleaseError('The previous Steam upload has an uncertain outcome. Check the Workshop '
                                   'item\'s change notes, then resume with --confirm-uploaded or --retry-upload.')
        elif confirm_uploaded or retry:
            raise ReleaseError('Steam resolution flags apply only to an uncertain upload; the last attempt '
                               'uploaded nothing. Resume without --confirm-uploaded/--retry-upload.')
        self.preflight()
        tool = self.workshoptool()
        manifest = Path(folder) / 'content.xml'
        before = manifest.read_bytes()
        state['upload_stage'] = 'sending'
        state['started'] = int(self.clock())
        save()
        try:
            # steam_appid.txt next to the tool is read from the working directory.
            result = self.run(update_command(tool, folder, notes, minor), cwd=str(Path(tool).parent),
                              capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=3600)
        except subprocess.TimeoutExpired:
            raise ReleaseError('WorkshopTool timed out; the upload outcome is uncertain.') from None
        output = ((result.stdout or '') + (result.stderr or '')).strip()
        (self.directory / (tag + '.log')).write_text(output + '\n', encoding='utf-8')
        unchanged = manifest.read_bytes() == before
        # MEASURED (WorkshopTool 1.15, exit 903): it stops before uploading anything
        # when it cannot reach Steam, so this outcome is certain, not uncertain.
        if unchanged and 'No connection to Steam servers' in output:
            state['upload_stage'] = 'pending'
            save()
            raise ReleaseError('WorkshopTool could not reach the Steam client; nothing was uploaded. '
                               'Check that the Steam client is online (Steam menu > Go Online), then resume. '
                               f'Full output: dist/steam/{tag}.log')
        # WorkshopTool rewrites the staged content.xml (lastupdate) only after an upload.
        if result.returncode or unchanged:
            tail = '\n'.join(output.splitlines()[-8:])
            raise ReleaseError(f'WorkshopTool did not confirm the upload (exit {result.returncode}); the outcome '
                               f'is uncertain. Full output: dist/steam/{tag}.log\n{tail}')
        state['upload_stage'] = 'done'
        save()
        print(f'Steam Workshop publication complete: {tag}, item {self.config["published_file_id"]}')
        return state
