import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { exactRepo } from '../common/Logic';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _params: AbilityConstant.LaunchParam): void {
    console.info('WristGitBoot: ability-created');
    this.acceptLink(want);
  }

  onNewWant(want: Want, _params: AbilityConstant.LaunchParam): void {
    this.acceptLink(want);
  }

  private acceptLink(want: Want): void {
    const text = want.parameters?.['ohos.extra.param.key.content'];
    const source = typeof text === 'string' ? text : (want.uri ?? '');
    if (source.length > 2048) { return; }
    const slug = exactRepo(source.replace(/^wristgit:\/\/repo\//i, 'https://github.com/'));
    if (slug) { AppStorage.setOrCreate('wristGitShared', slug); }
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    console.info('WristGitBoot: window-stage');
    try {
      stage.loadContent('pages/Index', (err: BusinessError) => {
        if (!err || !err.code) { console.info('WristGitBoot: content-loaded'); return; }
        console.error(`WristGitBoot: loadContent failed ${err.code}`);
      });
    } catch (_) { console.error('WristGitBoot: loadContent failed LOAD-START'); }
  }
}
