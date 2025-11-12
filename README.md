> [!NOTE]  
> This repository **will be archived** when Zig 0.16 is released in lieu of [Zig's new I/O](https://andrewkelley.me/post/zig-new-async-io-text-version.html) (which will include a more crossplatform approach to event loops via [Io.Evented](https://ziglang.org/documentation/master/std/#std.Io.Evented)).
> Additionally, the replacement of std.net with [std.Io.net](https://ziglang.org/documentation/master/std/#std.Io.net) will break this repository.
# Zig-Simple-HTTP-Server
## Building & Running
Using Zig 0.15.2, you can build the project
```
zig build
```
This will produce an executable. You can run the executable itself, or build and run the project with
```
zig build run
```

## Resources
Here's a list of resources I used to help me create this project
- https://pedropark99.github.io/zig-book/Chapters/04-http-server.html
- https://codeberg.org/dude_the_builder/subzed
- https://unixism.net/loti/tutorial/webserver_liburing.html
- https://github.com/karlseguin/http.zig
- https://www.openmymind.net/TCP-Server-In-Zig-Part-1-Single-Threaded/
- https://github.com/ziglang/zig/blob/master/lib/std/os/linux/IoUring.zig
