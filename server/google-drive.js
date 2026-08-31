const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');
const { GoogleAuth } = require('google-auth-library');

const DRIVE_API = 'https://www.googleapis.com/drive/v3';
const DEFAULT_FOLDER_ID = '11NyjeW1eKUYxnrGCqYaNKRyWm92DZwkS';
const DRIVE_READ_SCOPE = 'https://www.googleapis.com/auth/drive.readonly';
const ID_PATTERN = /^[A-Za-z0-9_-]{10,200}$/;

function configuredFolderId() {
  return String(process.env.GOOGLE_DRIVE_FOLDER_ID || DEFAULT_FOLDER_ID).trim();
}

function credentialsPath() {
  return process.env.GOOGLE_DRIVE_CREDENTIALS_PATH
    ? path.resolve(process.env.GOOGLE_DRIVE_CREDENTIALS_PATH)
    : path.join(__dirname, '..', 'firebase-service-account.json');
}

function googleDriveConfigured() {
  return ID_PATTERN.test(configuredFolderId()) && fs.existsSync(credentialsPath());
}

let auth;
function getAuth() {
  if (!googleDriveConfigured()) {
    throw new Error('Google Drive credentials or folder ID are not configured');
  }
  auth ??= new GoogleAuth({
    keyFile: credentialsPath(),
    scopes: [DRIVE_READ_SCOPE],
  });
  return auth;
}

async function authorizedFetch(url, options = {}) {
  const token = await getAuth().getAccessToken();
  if (!token) throw new Error('Google Drive access token was not issued');
  return fetch(url, {
    ...options,
    headers: {
      ...options.headers,
      Authorization: `Bearer ${token}`,
    },
  });
}

async function driveError(response) {
  let detail = '';
  try {
    const body = await response.json();
    detail = body?.error?.message || '';
  } catch (_) {}
  const error = new Error(detail || `Google Drive request failed (${response.status})`);
  error.status = response.status;
  return error;
}

async function listDriveFiles() {
  const folderId = configuredFolderId();
  const folderQuery = new URLSearchParams({
    fields: 'id,name,mimeType',
    supportsAllDrives: 'true',
  });
  const folderResponse = await authorizedFetch(
    `${DRIVE_API}/files/${encodeURIComponent(folderId)}?${folderQuery}`,
  );
  if (!folderResponse.ok) throw await driveError(folderResponse);
  const folder = await folderResponse.json();
  if (folder.mimeType !== 'application/vnd.google-apps.folder') {
    const error = new Error('The configured Google Drive item is not a folder');
    error.status = 400;
    throw error;
  }
  const query = new URLSearchParams({
    q: `'${folderId}' in parents and trashed=false`,
    pageSize: '1000',
    orderBy: 'folder,name_natural',
    fields: 'files(id,name,mimeType,size,createdTime,modifiedTime,webViewLink,thumbnailLink)',
    supportsAllDrives: 'true',
    includeItemsFromAllDrives: 'true',
  });
  const response = await authorizedFetch(`${DRIVE_API}/files?${query}`);
  if (!response.ok) throw await driveError(response);
  const body = await response.json();
  return {
    folder: { id: folder.id, name: folder.name },
    files: Array.isArray(body.files) ? body.files : [],
  };
}

async function getDriveFile(fileId) {
  if (!ID_PATTERN.test(fileId)) {
    const error = new Error('Invalid Google Drive file ID');
    error.status = 400;
    throw error;
  }
  const metadataQuery = new URLSearchParams({
    fields: 'id,name,mimeType,size,parents',
    supportsAllDrives: 'true',
  });
  const metadataResponse = await authorizedFetch(
    `${DRIVE_API}/files/${encodeURIComponent(fileId)}?${metadataQuery}`,
  );
  if (!metadataResponse.ok) throw await driveError(metadataResponse);
  const metadata = await metadataResponse.json();
  if (!Array.isArray(metadata.parents) ||
      !metadata.parents.includes(configuredFolderId())) {
    const error = new Error('The requested file is outside the configured Drive folder');
    error.status = 403;
    throw error;
  }
  if (String(metadata.mimeType).startsWith('application/vnd.google-apps.')) {
    const error = new Error('Google Workspace documents require an export format');
    error.status = 415;
    throw error;
  }
  const contentResponse = await authorizedFetch(
    `${DRIVE_API}/files/${encodeURIComponent(fileId)}?alt=media&supportsAllDrives=true`,
  );
  if (!contentResponse.ok) throw await driveError(contentResponse);
  return {
    metadata,
    stream: Readable.fromWeb(contentResponse.body),
  };
}

module.exports = {
  configuredFolderId,
  googleDriveConfigured,
  listDriveFiles,
  getDriveFile,
};
