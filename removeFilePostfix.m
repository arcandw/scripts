function removeFilePostfix(postfixToRemove)
    % removeFilePostfix - Removes a specific postfix from filenames in the current project
    % and updates all references
    %
    % Syntax:
    %   removeFilePostfix('_v1')
    %
    % Inputs:
    %   postfixToRemove - String postfix to remove (e.g., '_v1')
    
    % Get current project
    try
        prj = currentProject;
    catch e
        error('Failed to get current project: %s', e.message);
    end
    
    fprintf('Working with project: %s\n', prj.Name);
    
    % Check if Git is available
    gitAvailable = checkGitAvailable();
    if gitAvailable
        fprintf('Git is available. Changes will be tracked in Git.\n');
    else
        fprintf('Warning: Git not available or not a Git repository. Proceeding without Git tracking.\n');
    end
    
    % Define supported file types
    supportedFileTypes = {'.slx', '.mdl', '.m', '.lib', '.sldd', '.slmx', '.slreqx', '.xlsx', '.mldatx'};
    
    % Get all project files
    projectFiles = prj.Files;
    allFiles = {};
    
    % Filter for relevant file types
    for i = 1:length(projectFiles)
        filePath = projectFiles(i).Path;
        [~, ~, ext] = fileparts(filePath);
        if any(strcmpi(ext, supportedFileTypes))
            allFiles{end+1} = filePath;
        end
    end
    
    fprintf('Found %d relevant files in project.\n', numel(allFiles));
    
    % Find files containing the postfix
    filesToRename = {};
    for i = 1:length(allFiles)
        [~, filename, ext] = fileparts(allFiles{i});
        if contains(filename, postfixToRemove)
            filesToRename{end+1} = allFiles{i};
        end
    end
    
    fprintf('Found %d files with postfix "%s" to rename.\n', numel(filesToRename), safePrintf(postfixToRemove));
    
    % Process each file to rename
    renamedFiles = {};  % Keep track of successfully renamed files
    for i = 1:length(filesToRename)
        [folder, filename, ext] = fileparts(filesToRename{i});
        oldFileName = [filename, ext];
        newFileName = [strrep(filename, postfixToRemove, ''), ext];
        oldFilePath = filesToRename{i};
        newFilePath = fullfile(folder, newFileName);
        
        fprintf('Processing %d/%d: Renaming "%s" to "%s"\n', i, numel(filesToRename), safePrintf(oldFileName), safePrintf(newFileName));
        
        % 1. Find references to the file before renaming
        dependencies = findFileReferences(allFiles, oldFileName);
        fprintf('  Found %d files referencing %s\n', numel(dependencies), safePrintf(oldFileName));
        
        % 2. Rename the file
        try
            % Close file if open to prevent issues
            closeFileIfOpen(oldFilePath, ext, filename);
            
            % Remove file from project before renaming
            prj.removeFile(oldFilePath);
            
            % Handle Git renaming if available
            if gitAvailable
                [status, cmdout] = gitRenameFile(oldFilePath, newFilePath);
                if status ~= 0
                    fprintf('Warning: Git rename failed: %s\n', cmdout);
                    % Fall back to regular file move if Git rename fails
                    movefile(oldFilePath, newFilePath);
                end
            else
                % Regular file move if Git is not available
                movefile(oldFilePath, newFilePath);
            end
            
            % Add file back to project after renaming
            prj.addFile(newFilePath);
            
            % Verify the file was added to the project
            if ~isFileInProject(prj, newFilePath)
                fprintf('Warning: Failed to add %s back to project. Attempting again...\n', newFileName);
                prj.addFile(newFilePath);
                
                % Check again
                if ~isFileInProject(prj, newFilePath)
                    error('Failed to add %s to project after multiple attempts', newFileName);
                end
            end
            
            % Track successful rename
            renamedFiles{end+1} = struct('oldPath', oldFilePath, 'newPath', newFilePath);
            
        catch e
            fprintf('Error: Failed to rename %s: %s\n', safePrintf(oldFileName), safePrintf(e.message));
            % Try to restore file to project if rename failed
            try
                if ~isFileInProject(prj, oldFilePath)
                    prj.addFile(oldFilePath);
                    fprintf('  Restored original file %s to project\n', oldFileName);
                end
            catch restoreErr
                fprintf('  Failed to restore original file to project: %s\n', safePrintf(restoreErr.message));
            end
            continue;
        end
        
        % 3. Update references in all files
        fprintf('  Updating %d references...\n', length(dependencies));
        for j = 1:length(dependencies)
            fileToUpdate = dependencies{j};
            
            if isempty(fileToUpdate)
                continue;
            end
            
            try
                [~, ~, refExt] = fileparts(fileToUpdate);
                
                % Update references based on file type
                updateFileReferences(fileToUpdate, refExt, oldFileName, newFileName, gitAvailable);
                
            catch e
                fprintf('  Warning: Failed to update references in %s: %s\n', fileToUpdate, safePrintf(e.message));
            end
        end
        
        fprintf('  Successfully renamed %s to %s and updated references\n', oldFileName, newFileName);
    end
    
    fprintf('Renaming complete. %d files processed.\n', numel(filesToRename));
    fprintf('Successfully renamed %d/%d files.\n', numel(renamedFiles), numel(filesToRename));
    
    % Save the project to ensure all changes are persisted
    try
        prj.save();
        fprintf('Project saved successfully.\n');
    catch e
        fprintf('Warning: Failed to save project: %s\n', safePrintf(e.message));
    end
    
    % Summary of Git status if available
    if gitAvailable
        [status, cmdout] = system('git status --short');
        if status == 0
            if isempty(cmdout)
                fprintf('\nGit Status Summary: No changes detected\n');
            else
                fprintf('\nGit Status Summary:\n%s\n', safePrintf(cmdout));
            end
        else
            fprintf('\nFailed to get Git status\n');
        end
    end
end

% Helper function to close a file if it's open
function closeFileIfOpen(filePath, ext, filename)
    % For Simulink models and libraries
    if strcmpi(ext, '.slx') || strcmpi(ext, '.mdl') || strcmpi(ext, '.lib')
        if bdIsLoaded(filename)
            close_system(filename, 0);
        end
    % For Simulink data dictionaries
    elseif strcmpi(ext, '.sldd')
        try
            dictionary = Simulink.data.dictionary.open(filePath);
            dictionary.close();
        catch
            % Dictionary might not be open
        end
    % For Simulink Requirements
    elseif strcmpi(ext, '.slreqx')
        try
            % Close if requirements tools are available
            if exist('slreq.close', 'file')
                slreq.close(filePath);
            end
        catch
            % Requirements might not be open or the tools are not available
        end
    end
    % Other file types like Excel, MATLAB data files don't typically need explicit closing
end

% Helper function to update references in a file based on its type
function updateFileReferences(fileToUpdate, refExt, oldFileName, newFileName, gitAvailable)
    % Handle different file types
    switch lower(refExt)
        case {'.slx', '.mdl', '.lib'}
            % Update Simulink model/library references
            sys = load_system(fileToUpdate);
            replace_block(sys, 'SourceBlock', ['.*/' oldFileName], ['.*/' newFileName], 'REGEXP');
            save_system(sys);
            close_system(sys);
            fprintf('  Updated references in model/library: %s\n', fileToUpdate);
            
        case '.m'
            % Update MATLAB script references
            replaceInFile(fileToUpdate, oldFileName, newFileName);
            fprintf('  Updated references in script: %s\n', fileToUpdate);
            
        case '.sldd'
            % Update Simulink data dictionary references
            try
                dictionary = Simulink.data.dictionary.open(fileToUpdate);
                sectionNames = getSection(dictionary);
                for k = 1:length(sectionNames)
                    section = getSection(dictionary, sectionNames{k});
                    entryNames = getEntries(section);
                    for entryIdx = 1:length(entryNames)
                        try
                            entry = getEntry(section, entryNames{entryIdx});
                            if isprop(entry, 'Value') && ischar(entry.Value)
                                if contains(entry.Value, oldFileName)
                                    entry.Value = strrep(entry.Value, oldFileName, newFileName);
                                end
                            end
                        catch
                            % Skip entries that can't be processed
                        end
                    end
                end
                dictionary.saveChanges();
                dictionary.close();
                fprintf('  Updated references in data dictionary: %s\n', fileToUpdate);
            catch e
                fprintf('  Warning: Error updating data dictionary %s: %s\n', fileToUpdate, safePrintf(e.message));
            end
            
        case '.slmx'
            % Update Simulink model reference using specialized function
            try
                % Extract component names from the file names
                [~, oldComponentName, ~] = fileparts(oldFileName);
                [~, newComponentName, ~] = fileparts(newFileName);
                
                % Use specialized function for updating requirements links
                update_req_link_set_files(oldComponentName, oldFileName, newFileName);
                fprintf('  Updated references in model reference file using update_req_link_set_files: %s\n', fileToUpdate);
            catch e
                fprintf('  Warning: Error using update_req_link_set_files: %s\n', safePrintf(e.message));
                fprintf('  Falling back to XML-based update method...\n');
                
                % Fall back to XML-based update method
                updateSLMXReferences(fileToUpdate, oldFileName, newFileName);
            end
            
        case '.slreqx'
            % Update Simulink Requirements references
            % Requirements files are XML-based and can be edited as text
            replaceInFile(fileToUpdate, oldFileName, newFileName);
            fprintf('  Updated references in requirements file: %s\n', fileToUpdate);
            
        case '.xlsx'
            % For Excel files, warn that they need manual checking
            fprintf('  Warning: Excel file %s might contain references to %s. Please check manually.\n', fileToUpdate, oldFileName);
            
        case '.mldatx'
            % Update MATLAB data file references
            replaceInFile(fileToUpdate, oldFileName, newFileName);
            fprintf('  Updated references in MATLAB data file: %s\n', fileToUpdate);
            
        otherwise
            % For any other file type, try text-based replacement
            replaceInFile(fileToUpdate, oldFileName, newFileName);
            fprintf('  Attempted to update references in file: %s\n', fileToUpdate);
    end
    
    % Add modified file to Git if needed
    if gitAvailable
        [status, cmdout] = gitAdd(fileToUpdate);
        if status ~= 0
            fprintf('  Warning: Failed to add modified file %s to Git: %s\n', fileToUpdate, safePrintf(cmdout));
        end
    end
end

% Helper function for updating SLMX (Simulink Model Reference) files
function updateSLMXReferences(slmxPath, oldFileName, newFileName)
    try
        % Try to use update_req_link_set_files first (in case it wasn't called earlier)
        [~, oldComponentName, ~] = fileparts(oldFileName);
        [~, newComponentName, ~] = fileparts(newFileName);
        
        try
            update_req_link_set_files(oldComponentName, oldFileName, newFileName);
            fprintf('  Successfully updated SLMX file using update_req_link_set_files: %s\n', slmxPath);
            return; % Exit if successful
        catch
            % Continue with XML parsing approach if function call fails
            fprintf('  Continuing with XML parsing approach for %s\n', slmxPath);
        end
        
        % Use MATLAB's XML parser
        xDoc = xmlread(slmxPath);
        
        % Get reference nodes (specific to SLMX file structure)
        referenceNodes = xDoc.getElementsByTagName('modelReference');
        modified = false;
        
        % Process each reference node
        for i = 0:referenceNodes.getLength-1
            refNode = referenceNodes.item(i);
            
            % Check attributes that might contain file references
            attributes = {'ModelName', 'ModelFile', 'ModelPath'};
            
            for j = 1:length(attributes)
                attrName = attributes{j};
                attr = refNode.getAttributes.getNamedItem(attrName);
                
                if ~isempty(attr)
                    attrValue = char(attr.getNodeValue);
                    
                    % Check if this attribute contains our target file
                    if contains(attrValue, oldFileName)
                        % Update the reference
                        newValue = strrep(attrValue, oldFileName, newFileName);
                        attr.setNodeValue(newValue);
                        modified = true;
                        fprintf('  Updated reference in SLMX attribute %s\n', attrName);
                    end
                end
            end
        end
        
        % Also check ModelInformation nodes which may contain file references
        infoNodes = xDoc.getElementsByTagName('ModelInformation');
        for i = 0:infoNodes.getLength-1
            infoNode = infoNodes.item(i);
            nameAttr = infoNode.getAttributes.getNamedItem('name');
            
            if ~isempty(nameAttr)
                nameValue = char(nameAttr.getNodeValue);
                if contains(nameValue, oldFileName)
                    newValue = strrep(nameValue, oldFileName, newFileName);
                    nameAttr.setNodeValue(newValue);
                    modified = true;
                    fprintf('  Updated reference in SLMX ModelInformation\n');
                end
            end
        end
        
        % Save changes if any modifications were made
        if modified
            xmlwrite(slmxPath, xDoc);
            fprintf('  Successfully updated SLMX file: %s\n', slmxPath);
        end
        
    catch e
        fprintf('  Warning: Error updating SLMX file %s: %s\n', slmxPath, safePrintf(e.message));
        fprintf('  Falling back to text-based replacement...\n');
        
        % Fall back to text replacement as a safety mechanism
        replaceInFile(slmxPath, oldFileName, newFileName);
    end
end

% Check if a SLMX file references a specific file
function isReferencing = isSLMXReferencingFile(slmxPath, targetFileName, targetFileBase)
    isReferencing = false;
    try
        % Try to parse the SLMX as XML
        xDoc = xmlread(slmxPath);
        
        % Check reference nodes
        referenceNodes = xDoc.getElementsByTagName('modelReference');
        for i = 0:referenceNodes.getLength-1
            refNode = referenceNodes.item(i);
            
            % Check relevant attributes
            attributes = {'ModelName', 'ModelFile', 'ModelPath'};
            
            for j = 1:length(attributes)
                attrName = attributes{j};
                attr = refNode.getAttributes.getNamedItem(attrName);
                
                if ~isempty(attr)
                    attrValue = char(attr.getNodeValue);
                    if contains(attrValue, targetFileName) || contains(attrValue, targetFileBase)
                        isReferencing = true;
                        return;
                    end
                end
            end
        end
        
        % Check ModelInformation nodes
        infoNodes = xDoc.getElementsByTagName('ModelInformation');
        for i = 0:infoNodes.getLength-1
            infoNode = infoNodes.item(i);
            nameAttr = infoNode.getAttributes.getNamedItem('name');
            
            if ~isempty(nameAttr)
                nameValue = char(nameAttr.getNodeValue);
                if contains(nameValue, targetFileName) || contains(nameValue, targetFileBase)
                    isReferencing = true;
                    return;
                end
            end
        end
        
    catch e
        % If XML parsing fails, fall back to text-based checking
        isReferencing = isTextFileReferencingFile(slmxPath, targetFileName, targetFileBase);
    end
end

% Helper function to find files that reference the target file
function dependencies = findFileReferences(allFiles, targetFileName)
    dependencies = {};
    
    % Extract target file name without extension for better matching
    [~, targetFileBase, targetFileExt] = fileparts(targetFileName);
    
    for i = 1:length(allFiles)
        filePath = allFiles{i};
        [~, ~, ext] = fileparts(filePath);
        
        try
            % Check references based on file type
            isReferencing = false;
            
            % For Simulink models, libraries and related files
            if any(strcmpi(ext, {'.slx', '.mdl', '.lib'}))
                isReferencing = isModelOrLibraryReferencingFile(filePath, targetFileName, targetFileBase);
            
            % For Simulink model references (SLMX)
            elseif strcmpi(ext, '.slmx')
                isReferencing = isSLMXReferencingFile(filePath, targetFileName, targetFileBase);
            
            % For Simulink data dictionary
            elseif strcmpi(ext, '.sldd')
                isReferencing = isDataDictionaryReferencingFile(filePath, targetFileName, targetFileBase);
                
            % For Simulink Requirements
            elseif strcmpi(ext, '.slreqx')
                isReferencing = isTextFileReferencingFile(filePath, targetFileName, targetFileBase);
            
            % For MATLAB scripts and other text-based files
            elseif strcmpi(ext, '.m') || strcmpi(ext, '.mldatx')
                isReferencing = isTextFileReferencingFile(filePath, targetFileName, targetFileBase);
            
            % For Excel files - we can't easily check Excel content
            elseif strcmpi(ext, '.xlsx')
                % Skip checking Excel files - would require spreadsheet API
                isReferencing = false;
            end
            
            if isReferencing
                dependencies{end+1} = filePath;
            end
            
        catch e
            fprintf('  Warning: Failed to check references in %s: %s\n', filePath, safePrintf(e.message));
        end
    end
end

% Check if a Simulink model or library references a specific file
function isReferencing = isModelOrLibraryReferencingFile(modelPath, targetFileName, targetFileBase)
    isReferencing = false;
    try
        % Don't load already loaded models again
        [~, modelName, ext] = fileparts(modelPath);
        isLibrary = strcmpi(ext, '.lib') || strcmpi(ext, '.mdl') && (exist([modelName '.mdl'], 'file') && ~isempty(find_system(modelName, 'BlockType', 'SubSystem', 'IsLibrary', 'on')));
        
        % First, check if the model is already loaded
        if ~bdIsLoaded(modelName)
            % Load the model or library
            if isLibrary
                load_system(modelName, 'Library');
            else
                load_system(modelPath);
            end
            needsClosing = true;
        else
            needsClosing = false;
        end
        
        % 1. For models, use find_mdlrefs to find model references
        if ~isLibrary
            try
                refModels = find_mdlrefs(modelName);
                for i = 1:length(refModels)
                    % Compare with target file name
                    [~, refModelName, ~] = fileparts(refModels{i});
                    if strcmpi(refModelName, targetFileBase) || contains(lower(refModelName), lower(targetFileBase))
                        isReferencing = true;
                        break;
                    end
                end
            catch
                % Continue with alternative methods even if find_mdlrefs fails
            end
        end
        
        % 2. If not yet found or is a library, check for library links and block references
        if ~isReferencing
            % Different ways to search for library references
            searchPatterns = {
                lower(targetFileName),                  % Full filename with extension
                lower(targetFileBase),                  % Just the base name
                lower([targetFileBase, '/']),           % Base name followed by path separator
                lower(['/', targetFileBase]),           % Path separator followed by base name
                lower(strrep(targetFileName, '.', '/')) % Replace dots with path separators
            };
            
            % Get all blocks in the model/library
            allBlocks = find_system(modelName, 'FollowLinks', 'on', 'LookUnderMasks', 'all');
            
            for i = 1:length(allBlocks)
                try
                    % Check different block parameters that might contain references
                    paramNames = {'SourceBlock', 'ReferenceBlock', 'LibraryBlock', 'ReferencedLibrary'};
                    
                    for p = 1:length(paramNames)
                        try
                            paramValue = get_param(allBlocks{i}, paramNames{p});
                            if ~isempty(paramValue)
                                paramLower = lower(paramValue);
                                % Check against all search patterns
                                for j = 1:length(searchPatterns)
                                    if contains(paramLower, searchPatterns{j})
                                        isReferencing = true;
                                        break;
                                    end
                                end
                                if isReferencing
                                    break;
                                end
                            end
                        catch
                            % Parameter doesn't exist for this block
                        end
                    end
                    
                    if isReferencing
                        break;
                    end
                catch
                    % Skip blocks that cause errors
                    continue;
                end
            end
        end
        
        % Close model if we opened it
        if needsClosing
            close_system(modelName, 0);
        end
    catch e
        fprintf('  Warning: Error checking model/library %s for references: %s\n', modelPath, safePrintf(e.message));
    end
end

% Check if a data dictionary references a specific file
function isReferencing = isDataDictionaryReferencingFile(filePath, targetFileName, targetFileBase)
    isReferencing = false;
    try
        % Try to open the data dictionary
        dictionary = Simulink.data.dictionary.open(filePath);
        
        % Get all sections
        sectionNames = getSection(dictionary);
        
        % Check each section for references
        for k = 1:length(sectionNames)
            try
                section = getSection(dictionary, sectionNames{k});
                entryNames = getEntries(section);
                
                for entryIdx = 1:length(entryNames)
                    try
                        entry = getEntry(section, entryNames{entryIdx});
                        
                        % Check if the entry value contains the target name
                        if isprop(entry, 'Value') && ischar(entry.Value)
                            if contains(entry.Value, targetFileName) || contains(entry.Value, targetFileBase)
                                isReferencing = true;
                                break;
                            end
                        end
                    catch
                        % Skip entries that can't be processed
                    end
                end
                
                if isReferencing
                    break;
                end
            catch
                % Skip sections that can't be processed
            end
        end
        
        % Close the dictionary
        dictionary.close();
    catch e
        % If we can't open the dictionary, fall back to text-based checking
        isReferencing = isTextFileReferencingFile(filePath, targetFileName, targetFileBase);
    end
end

% Check if a text-based file references a specific file
function isReferencing = isTextFileReferencingFile(filePath, targetFileName, targetFileBase)
    isReferencing = false;
    try
        % Read file content
        fid = fopen(filePath, 'r');
        if fid == -1
            error('Could not open file: %s', filePath);
        end
        content = fread(fid, '*char')';
        fclose(fid);
        
        % Check if content contains the target file name - check both full name and base name
        isReferencing = contains(content, targetFileName) || contains(content, targetFileBase);
    catch e
        fprintf('  Warning: Error checking file %s for references: %s\n', filePath, safePrintf(e.message));
    end
end

% Helper function to replace text in files
function replaceInFile(filePath, oldText, newText)
    try
        % Read file content
        fid = fopen(filePath, 'r');
        if fid == -1
            error('Could not open file: %s', safePrintf(filePath));
        end
        content = fread(fid, '*char')';
        fclose(fid);
        
        % Replace text
        newContent = strrep(content, oldText, newText);
        
        % Write back to file
        fid = fopen(filePath, 'w');
        if fid == -1
            error('Could not open file for writing: %s', safePrintf(filePath));
        end
        fwrite(fid, newContent);  % Using fwrite instead of fprintf to avoid format issues
        fclose(fid);
    catch e
        fprintf('  Warning: Error replacing text in file %s: %s\n', safePrintf(filePath), safePrintf(e.message));
    end
end

% Helper function to safely convert values for fprintf
function safeStr = safePrintf(inputStr)
    if isempty(inputStr)
        safeStr = '';
    elseif ischar(inputStr) || isstring(inputStr)
        safeStr = char(inputStr); % Ensure it's a character array
    elseif isnumeric(inputStr)
        if isa(inputStr, 'int64') || isa(inputStr, 'uint64')
            % Special handling for 64-bit integers to avoid conversion issues
            safeStr = sprintf('%d', double(inputStr));
        else
            safeStr = num2str(inputStr);
        end
    elseif iscell(inputStr) && ~isempty(inputStr)
        % If it's a cell, try to convert cell contents to string
        try
            if ischar(inputStr{1}) || isstring(inputStr{1})
                safeStr = char(inputStr{1});
            else
                safeStr = '<unprintable cell content>';
            end
        catch
            safeStr = '<unprintable cell content>';
        end
    else
        % For any other type, return a generic message
        safeStr = '<unprintable content>';
    end
end

% Helper function to check if Git is available
function available = checkGitAvailable()
    [status, ~] = system('git rev-parse --is-inside-work-tree');
    available = (status == 0);
end

% Helper function to rename file with Git
function [status, cmdout] = gitRenameFile(oldPath, newPath)
    command = sprintf('git mv "%s" "%s"', safePrintf(oldPath), safePrintf(newPath));
    [status, cmdout] = system(command);
end

% Helper function to add file to Git
function [status, cmdout] = gitAdd(filePath)
    command = sprintf('git add "%s"', safePrintf(filePath));
    [status, cmdout] = system(command);
end

% Helper function to check if a file is in the project
function inProject = isFileInProject(project, filePath)
    projectFiles = project.Files;
    inProject = false;
    
    % Normalize path for comparison
    normFilePath = strrep(lower(filePath), '\', '/');
    
    for i = 1:length(projectFiles)
        normProjPath = strrep(lower(projectFiles(i).Path), '\', '/');
        if strcmp(normProjPath, normFilePath)
            inProject = true;
            break;
        end
    end
end