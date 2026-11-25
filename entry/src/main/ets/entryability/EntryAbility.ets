import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { exactRepo } from '../common/Logic';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, _params: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('wristGitShared', '');
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
    stage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error(`WristGit loadContent failed: ${err.code}`);
      }
    });
  }
}
