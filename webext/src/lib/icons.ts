// Pick a lucide icon for a Safari tab group from its name (English and Spanish keywords),
// and one for each device kind. First match wins, so specific themes come before broad ones.
import {
  AppWindowIcon,
  BookOpenIcon,
  BriefcaseIcon,
  CameraIcon,
  CarIcon,
  ChefHatIcon,
  CodeIcon,
  CpuIcon,
  DownloadIcon,
  DumbbellIcon,
  FeatherIcon,
  FolderIcon,
  FootprintsIcon,
  Gamepad2Icon,
  GraduationCapIcon,
  HeartPulseIcon,
  HouseIcon,
  LaptopIcon,
  ListTodoIcon,
  MonitorIcon,
  MusicIcon,
  NewspaperIcon,
  PaintbrushIcon,
  PaletteIcon,
  PlaneIcon,
  ServerIcon,
  ShirtIcon,
  ShoppingBagIcon,
  SmartphoneIcon,
  SparklesIcon,
  SquareTerminalIcon,
  TabletIcon,
  VideoIcon,
  WalletIcon,
  type LucideIcon,
} from "lucide-react"
import type { DeviceKind } from "./ext"

const RULES: [RegExp, LucideIcon][] = [
  [
    /sneaker|\bshoes?\b|zapat|\btenis\b|footwear|\bjordans?\b|\bnike\b/,
    FootprintsIcon,
  ],
  [
    /cloth|\bropa\b|fashion|\bmoda\b|\bsuits?\b|\btrajes?\b|outfit|shirt|camisa|\bwear\b|streetwear/,
    ShirtIcon,
  ],
  [/\bcss\b|\bstyles?\b|\bestilos?\b|tailwind|stylesheet/, PaintbrushIcon],
  [
    /design|diseñ|\bui\b|\bux\b|figma|\bcolou?rs?\b|palette|\bbrand|\blogos?\b|\bart\b|\barte\b/,
    PaletteIcon,
  ],
  [
    /\binks?\b|\btintas?\b|\bplumas?\b|\bpens?\b|fountain|caligraf|calligra|\bwrit|\bescrit/,
    FeatherIcon,
  ],
  [
    /\blearn|aprend|\bcourses?\b|\bcursos?\b|\bstudy|\bestudi|tutorial|\bclass(es)?\b|\bclases?\b|school|escuela/,
    GraduationCapIcon,
  ],
  [
    /esp32|esp8266|arduino|electr|\bcpu\b|\bchips?\b|hardware|\bpcb\b|\biot\b|\bsensors?\b/,
    CpuIcon,
  ],
  [
    /raspberry|self.?host|\bservers?\b|servidor|homelab|docker|\bnas\b|\binfra/,
    ServerIcon,
  ],
  [/terminal|\bcli\b|\bshell\b|\bt3\b/, SquareTerminalIcon],
  [
    /program|\bcode\b|código|codigo|\bdev\b|develop|angular|\breact\b|\bvue\b|svelte|\bswift\b|python|\brust\b|\bjs\b|typescript/,
    CodeIcon,
  ],
  [/\btask|\btareas?\b|\btodos?\b|to-do|pendiente/, ListTodoIcon],
  [/download|descarga/, DownloadIcon],
  [/\bapps?\b|aplicaci|software|\btools\b|herramient/, AppWindowIcon],
  [
    /\bshop|\bcompras?\b|\bbuy\b|tienda|\bstores?\b|wishlist|\bdeseos?\b/,
    ShoppingBagIcon,
  ],
  [/music|música|musica|\bsongs?\b|spotify|playlist/, MusicIcon],
  [
    /\bvideos?\b|youtube|\bmovies?\b|película|pelicula|\bfilms?\b|watch ?later/,
    VideoIcon,
  ],
  [
    /travel|\bviajes?\b|\btrips?\b|vacation|vacacion|\bflights?\b|\bvuelos?\b|\bhotels?\b/,
    PlaneIcon,
  ],
  [/recipe|receta|\bfood\b|comida|\bcook|cocina/, ChefHatIcon],
  [/\bwork\b|trabajo|\bjobs?\b|empleo|\boffice\b|oficina/, BriefcaseIcon],
  [
    /\bfinan|\bmoney\b|dinero|\bbank|\bbanco|\binvest|budget|presupuesto/,
    WalletIcon,
  ],
  [/\bgames?\b|\bjuegos?\b|gaming/, Gamepad2Icon],
  [/\bnews\b|noticia|\barticles?\b|artículo|\bblogs?\b/, NewspaperIcon],
  [/\bbooks?\b|\blibros?\b|\bread(ing)?\b|\blectura|\bleer\b/, BookOpenIcon],
  [/\bphoto|\bfoto|\bcameras?\b|cámara|camara/, CameraIcon],
  [/\bgym\b|fitness|workout|ejercicio/, DumbbellIcon],
  [/health|\bsalud\b|\bmedic|\bdoctor/, HeartPulseIcon],
  [/\bhome\b|\bcasa\b|\bhogar\b|\bhouse\b|furniture|\bmuebles?\b/, HouseIcon],
  [/\bcars?\b|\bautos?\b|\bcoches?\b|\bcarros?\b|vehic/, CarIcon],
  [/\bai\b|\bia\b|gpt|claude|llm|machine learning/, SparklesIcon],
]

export function iconForGroup(title: string): LucideIcon {
  const t = title.toLowerCase()
  for (const [re, icon] of RULES) if (re.test(t)) return icon
  return FolderIcon
}

export function iconForDevice(kind?: DeviceKind): LucideIcon {
  switch (kind) {
    case "phone":
      return SmartphoneIcon
    case "tablet":
      return TabletIcon
    case "laptop":
      return LaptopIcon
    default:
      return MonitorIcon
  }
}
