export class FavoriteGroup {
  name: string;
  slugs: string[];
  constructor(name: string, slugs: string[] = []) {
    this.name = name;
    this.slugs = slugs;
  }
}

export function groupName(raw: string): string {
  return raw.trim().replace(/\s+/g, ' ').slice(0, 24);
}

export function belongs(group: FavoriteGroup, slug: string): boolean {
  return group.slugs.includes(slug.toLowerCase());
}

export function setMembership(groups: FavoriteGroup[], name: string, slug: string, active: boolean): FavoriteGroup[] {
  const key = slug.toLowerCase();
  return groups.map((group: FavoriteGroup) => {
    if (group.name !== name) { return group; }
    const slugs = group.slugs.filter((entry: string) => entry !== key);
    if (active) { slugs.push(key); }
    return new FavoriteGroup(group.name, slugs);
  });
}

export function removeFromGroups(groups: FavoriteGroup[], slug: string): FavoriteGroup[] {
  const key = slug.toLowerCase();
  return groups.map((group: FavoriteGroup) => new FavoriteGroup(group.name,
    group.slugs.filter((entry: string) => entry !== key)));
}
