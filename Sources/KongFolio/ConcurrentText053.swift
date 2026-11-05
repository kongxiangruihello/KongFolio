import Foundation

enum ConcurrentText053 {
    struct Result { var text:String;var conflict:Bool }
    struct Edit { var range:NSRange;var replacement:String }
    static func edit(_ base:String,_ changed:String)->Edit {
        let prefix=String(zip(base,changed).prefix{$0==$1}.map(\.0)).utf16.count
        let suffix=String(zip(base.reversed(),changed.reversed()).prefix{$0==$1}.map(\.0)).utf16.count
        let tail=min(suffix,min(base.utf16.count-prefix,changed.utf16.count-prefix))
        return Edit(range:NSRange(location:prefix,length:base.utf16.count-prefix-tail),replacement:(changed as NSString).substring(with:NSRange(location:prefix,length:changed.utf16.count-prefix-tail)))
    }
    static func merge(base:String,local:String,external:String,singleLine:Bool=false)->Result {
        if local==external || external==base { return Result(text:local,conflict:false) }
        if local==base { return Result(text:external,conflict:false) }
        let a=edit(base,local),b=edit(base,external)
        // Adjacent insertions at the same cursor are ambiguous, and retain both full versions.
        let disjoint=NSMaxRange(a.range)<=b.range.location || NSMaxRange(b.range)<=a.range.location
        if disjoint && !(a.range.location==b.range.location && (a.range.length==0 || b.range.length==0)) {
            let value=NSMutableString(string:base)
            for e in [a,b].sorted(by:{$0.range.location>$1.range.location}) { value.replaceCharacters(in:e.range,with:e.replacement) }
            return Result(text:value as String,conflict:false)
        }
        let text=singleLine ? local+" / "+external : local+"\n\n---\n\n同时编辑保留的另一版本：\n\n"+external
        return Result(text:text,conflict:true)
    }
}
