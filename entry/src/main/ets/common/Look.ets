export class Look {
  readonly bg: string;
  readonly glow: string;
  readonly low: string;
  readonly ink: string;
  readonly muted: string;
  readonly blue: string;
  readonly accentText: string;
  readonly pale: string;
  readonly border: string;
  readonly card: string;
  readonly shadow: string;
  readonly chart: string[];
  constructor(dark: boolean) {
    this.bg = dark ? '#000000' : '#F5F7FB';
    this.glow = dark ? '#101A26' : '#E9F2FF';
    this.low = dark ? '#06080D' : '#F4F0FF';
    this.ink = dark ? '#EFF5FF' : '#142238';
    this.muted = dark ? '#A7B5C8' : '#50627A';
    this.blue = dark ? '#89B6FF' : '#1759E8';
    this.accentText = dark ? '#061833' : '#FFFFFF';
    this.pale = dark ? '#14243C' : '#E7EEFF';
    this.border = dark ? '#283446' : '#D9E3F1';
    this.card = dark ? '#11161F' : '#FFFFFF';
    this.shadow = dark ? '#99000000' : '#22415E88';
    this.chart = dark ? ['#7EAEFF', '#5DDBCC', '#FFC176', '#A6B9D1'] : ['#2265F2', '#008476', '#A25703', '#596B83'];
  }
}

export const DAY_LOOK: Look = new Look(false);
export const NIGHT_LOOK: Look = new Look(true);
