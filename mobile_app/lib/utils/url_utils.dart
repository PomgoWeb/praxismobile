String ensureTrailingSlash(String baseUrl) {
  if (baseUrl.endsWith('/')) {
    return baseUrl;
  }
  return '$baseUrl/';
}

String normalizePath(String path) {
  final String trimmed = path.trim();
  if (trimmed.isEmpty) return '/';
  if (trimmed.startsWith('/')) return trimmed;
  return '/$trimmed';
}

Uri buildUrl(String baseUrl, String path) {
  final String normalizedBase = ensureTrailingSlash(baseUrl);
  final String normalizedPath = normalizePath(path);
  final String merged = normalizedPath.substring(1);
  return Uri.parse(normalizedBase).resolve(merged);
}

bool isAbsoluteUrl(String value) {
  final Uri? uri = Uri.tryParse(value);
  return uri != null && uri.hasScheme && uri.host.isNotEmpty;
}

bool isSameDomainOrSubdomain(Uri baseUri, Uri candidateUri) {
  final String baseHost = baseUri.host.toLowerCase();
  final String candidateHost = candidateUri.host.toLowerCase();
  return candidateHost == baseHost || candidateHost.endsWith('.$baseHost');
}
