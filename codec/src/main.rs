use frameshift_codec::{Error, MAX_SOURCE, REVISION, header, normalize};
use std::io::{Read, Write};

fn read_source() -> Result<Vec<u8>, Error> {
    let mut input = std::io::stdin().lock();
    let mut length = [0; 4];
    input
        .read_exact(&mut length)
        .map_err(|_| Error::Malformed)?;
    let length = u32::from_be_bytes(length) as usize;
    if length == 0 || length > MAX_SOURCE {
        return Err(Error::Bounds);
    }
    let mut source = Vec::new();
    source
        .try_reserve_exact(length)
        .map_err(|_| Error::Allocation)?;
    source.resize(length, 0);
    input
        .read_exact(&mut source)
        .map_err(|_| Error::Malformed)?;
    let mut extra = [0];
    if input.read(&mut extra).map_err(|_| Error::Malformed)? != 0 {
        return Err(Error::Malformed);
    }
    Ok(source)
}

fn main() {
    let arguments: Vec<_> = std::env::args_os().skip(1).collect();
    if arguments.as_slice() == [std::ffi::OsString::from("--version")] {
        println!("{REVISION}");
        return;
    }
    if !arguments.is_empty() {
        eprintln!("usage: frameshift-codec [--version]");
        std::process::exit(64);
    }
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(|| read_source().and_then(|source| normalize(&source)))
        .unwrap_or(Err(Error::Internal));
    let mut output = std::io::stdout().lock();
    let wrote = output
        .write_all(&header(&result))
        .and_then(|()| {
            if let Ok(image) = &result {
                output.write_all(&image.rgba)
            } else {
                Ok(())
            }
        })
        .and_then(|()| output.flush());
    if wrote.is_err() {
        std::process::exit(74);
    }
}
