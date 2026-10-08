///|
priv struct FakeBrowserOpener {
  opened : Array[String]
}

///|
impl BrowserOpener for FakeBrowserOpener with fn open(self, url) {
  self.opened.push(url)
  Ok(())
}
