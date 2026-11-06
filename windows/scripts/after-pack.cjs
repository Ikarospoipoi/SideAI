const fs=require('node:fs');
const path=require('node:path');
// npm ships its own dependency tree. electron-builder's dependency collector
// flattens / prunes it; preserve this standalone CLI exactly as distributed.
module.exports=async context=>{
  const resources=context.electronPlatformName==='darwin'
    ?path.join(context.appOutDir,context.packager.appInfo.productFilename+'.app','Contents','Resources')
    :path.join(context.appOutDir,'resources');
  const source=path.dirname(require.resolve('npm/package.json'));
  fs.cpSync(source,path.join(resources,'installer','npm'),{recursive:true,dereference:true});
};
